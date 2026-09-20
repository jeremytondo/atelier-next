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
    /// The chord lent to macOS, and whether Atelier binds it and so registers
    /// it again afterwards.
    var lent: (chord: Chord, isBound: Bool)?
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
  /// Returns why each chord that could not be registered was refused. A chord
  /// on loan to macOS waits for `reclaim`.
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
      state.lent?.isBound = false
      var refused: [Chord: String] = [:]
      for chord in chords {
        if chord == state.lent?.chord {
          state.lent?.isBound = true
        } else if let reason = Self.register(chord, codes: codes, in: &state) {
          refused[chord] = reason
        }
      }
      return refused
    }
  }

  /// Stops catching a chord while macOS is sent it: a registered chord reaches
  /// Atelier and nothing else, Dock included. One chord at a time, as commands
  /// run. False when another is lent already or macOS keeps the registration.
  @MainActor func lend(_ chord: Chord) -> Bool {
    state.withLock { state in
      guard state.lent == nil else { return false }
      var isBound = false
      for (id, registered) in state.registered where registered.chord == chord {
        guard UnregisterEventHotKey(registered.reference) == noErr else { return false }
        state.registered[id] = nil
        // Its key-up reaches no one now.
        state.held.remove(id)
        isBound = true
      }
      state.lent = (chord, isBound)
      return true
    }
  }

  /// Registers the lent chord again if Atelier binds it, going by the bindings
  /// of now, under a new number so that nothing queued for the old one counts
  /// as a press. Returns why macOS refused, if it did.
  @MainActor func reclaim() -> String? {
    let codes = KeyCodes()
    return state.withLock { state in
      guard let lent = state.lent else { return nil }
      state.lent = nil
      return lent.isBound ? Self.register(lent.chord, codes: codes, in: &state) : nil
    }
  }

  /// Nil once the chord is registered; otherwise why it was refused.
  private static func register(_ chord: Chord, codes: KeyCodes, in state: inout State) -> String? {
    guard !chord.modifiers.contains(.function) else {
      return "Shortcuts with Fn are not supported."
    }
    guard let code = codes.code(for: chord.key) else {
      return "The current keyboard layout has no \(chord.key) key."
    }
    let id = EventHotKeyID(signature: signature, id: state.next)
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(code), carbonModifiers(chord.modifiers), id, GetEventDispatcherTarget(), 0,
      &reference)
    guard status == noErr, let reference else {
      return status == eventHotKeyExistsErr
        ? "Another app has registered this shortcut."
        : "macOS refused the shortcut (\(status))."
    }
    state.registered[state.next] = (reference, chord)
    state.next += 1
    return nil
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
  /// while `replace`, `lend`, or `reclaim`, also on the main thread, holds the
  /// lock.
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
