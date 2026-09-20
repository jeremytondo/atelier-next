import Carbon.HIToolbox
import Synchronization

/// Atelier's global keyboard shortcuts, registered with macOS through Carbon.
/// A registered chord reaches Atelier before any app and no app sees it; a
/// chord already taken by another app is refused, and nothing is done to
/// make it available. Chords with Fn cannot be registered this way.
///
/// Carbon repeats the pressed event while a key is held; a chord counts once
/// per press, until its release. One instance serves the whole process and
/// lives as long as it does, since Carbon holds a bare pointer to it.
final class HotKeys: Sendable {
  private struct State {
    var registered: [UInt32: (reference: EventHotKeyRef?, chord: Chord)] = [:]
    var released: [Chord: Int] = [:]
    var next: UInt32 = 1
    var held: Set<UInt32> = []
    var handler: EventHandlerRef?
  }

  private static let signature = OSType(0x4154_4C52)  // "ATLR"

  private let state = Mutex(State())
  private let pressed = AsyncStream.makeStream(
    of: Chord.self, bufferingPolicy: .bufferingNewest(16))

  /// Every press of a registered chord, for one listener.
  func presses() -> AsyncStream<Chord> {
    pressed.stream
  }

  /// Registers exactly these chords, releasing every chord registered before.
  /// Returns why each chord that could not be registered was refused.
  @MainActor func replace(_ chords: [Chord]) -> [Chord: String] {
    let codes = KeyCodes()
    return state.withLock { state in
      if state.handler == nil { state.handler = installHandler() }
      guard state.handler != nil else {
        // Registering without a handler would take the keys and do nothing.
        return Dictionary(
          uniqueKeysWithValues: chords.map { ($0, "macOS refused Atelier's shortcut handler.") })
      }
      for (_, registered) in state.registered {
        if let reference = registered.reference { UnregisterEventHotKey(reference) }
      }
      state.registered = [:]
      state.held = []
      var refused: [Chord: String] = [:]
      for chord in chords {
        guard !chord.modifiers.contains(.function) else {
          refused[chord] = "Shortcuts with Fn are not supported."
          continue
        }
        guard let code = codes.code(for: chord.key) else {
          refused[chord] = "The current keyboard layout has no \(chord.key) key."
          continue
        }
        var reference: EventHotKeyRef?
        if state.released[chord] == nil {
          let status = register(chord, code: code, id: state.next, reference: &reference)
          guard status == noErr, reference != nil else {
            refused[chord] = Self.reason(status)
            continue
          }
        }
        state.registered[state.next] = (reference, chord)
        state.next += 1
      }
      return refused
    }
  }

  /// Carbon consumes registered shortcuts before Dock can match them. Release
  /// only the chord being posted, including across a configuration reload, then
  /// restore the current binding. A key-up during this interval is not delivered
  /// to Carbon, so its held state must be cleared too.
  @MainActor func release(_ chord: Chord) -> Bool {
    state.withLock { state in
      state.released[chord, default: 0] += 1
      guard state.released[chord] == 1 else { return true }
      for (id, registered) in state.registered where registered.chord == chord {
        if let reference = registered.reference, UnregisterEventHotKey(reference) != noErr {
          state.released[chord] = nil
          return false
        }
        state.registered[id]?.reference = nil
        state.held.remove(id)
      }
      return true
    }
  }

  /// A failure to restore is reported to the command that borrowed the chord.
  @MainActor func restore(_ chord: Chord) -> String? {
    let codes = KeyCodes()
    return state.withLock { state in
      guard let count = state.released[chord] else { return nil }
      guard count == 1 else {
        state.released[chord] = count - 1
        return nil
      }
      state.released[chord] = nil
      for (id, registered) in state.registered where registered.chord == chord {
        guard let code = codes.code(for: chord.key) else {
          return "The current keyboard layout has no \(chord.key) key."
        }
        var reference: EventHotKeyRef?
        let status = register(chord, code: code, id: state.next, reference: &reference)
        guard status == noErr, reference != nil else { return Self.reason(status) }
        // Queued events for the old registration must not become a new press.
        state.registered[id] = nil
        state.registered[state.next] = (reference, chord)
        state.next += 1
        state.held.remove(id)
      }
      return nil
    }
  }

  private func register(
    _ chord: Chord, code: CGKeyCode, id: UInt32, reference: inout EventHotKeyRef?
  ) -> OSStatus {
    RegisterEventHotKey(
      UInt32(code), Self.carbonModifiers(chord.modifiers),
      EventHotKeyID(signature: Self.signature, id: id), GetEventDispatcherTarget(), 0, &reference)
  }

  private static func reason(_ status: OSStatus) -> String {
    status == eventHotKeyExistsErr
      ? "Another app has registered this shortcut."
      : "macOS refused the shortcut (\(status))."
  }

  private static func carbonModifiers(_ modifiers: Chord.Modifiers) -> UInt32 {
    var flags: Int = 0
    if modifiers.contains(.command) { flags |= cmdKey }
    if modifiers.contains(.option) { flags |= optionKey }
    if modifiers.contains(.control) { flags |= controlKey }
    if modifiers.contains(.shift) { flags |= shiftKey }
    return UInt32(flags)
  }

  private func installHandler() -> EventHandlerRef? {
    var kinds = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    var handler: EventHandlerRef?
    let callback: EventHandlerUPP = { _, event, pointer in
      guard let event, let pointer else { return noErr }
      var id = EventHotKeyID()
      GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &id)
      Unmanaged<HotKeys>.fromOpaque(pointer).takeUnretainedValue()
        .handle(id.id, released: GetEventKind(event) == UInt32(kEventHotKeyReleased))
      return noErr
    }
    let status = InstallEventHandler(
      GetEventDispatcherTarget(), callback, kinds.count, &kinds,
      Unmanaged.passUnretained(self).toOpaque(), &handler)
    return status == noErr ? handler : nil
  }

  /// Called by Carbon on the main thread between run-loop turns, so never
  /// while `replace`, also on the main thread, holds the lock.
  private func handle(_ id: UInt32, released: Bool) {
    let chord: Chord? = state.withLock { state in
      guard let registered = state.registered[id], registered.reference != nil else { return nil }
      if released {
        state.held.remove(id)
        return nil
      }
      guard state.held.insert(id).inserted else { return nil }
      return registered.chord
    }
    if let chord { pressed.continuation.yield(chord) }
  }
}
