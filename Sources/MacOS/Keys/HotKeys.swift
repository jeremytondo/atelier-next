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
    var registered: [UInt32: (reference: EventHotKeyRef, chord: Chord)] = [:]
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
        UnregisterEventHotKey(registered.reference)
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
        let id = EventHotKeyID(signature: Self.signature, id: state.next)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
          UInt32(code), Self.carbonModifiers(chord.modifiers), id, GetEventDispatcherTarget(), 0,
          &reference)
        guard status == noErr, let reference else {
          refused[chord] =
            status == eventHotKeyExistsErr
            ? "Another app has registered this shortcut."
            : "macOS refused the shortcut (\(status))."
          continue
        }
        state.registered[state.next] = (reference, chord)
        state.next += 1
      }
      return refused
    }
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
      guard let registered = state.registered[id] else { return nil }
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
