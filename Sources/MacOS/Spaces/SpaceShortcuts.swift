import CoreGraphics
import Foundation

/// Switches Desktops through Dock's native shortcuts. Direct WindowServer
/// switching leaves Dock's windows and menu bar behind. A matching Atelier
/// shortcut is released while the native key is posted, then restored; native
/// assignments therefore do not exclude Atelier's own bindings.
///
/// Disabled native shortcuts are borrowed for the whole confirmed transition,
/// not a timer independent of it. Only login-session state is changed, never
/// saved preferences. If Atelier dies while borrowing, the key stays enabled
/// until logout.
/// The workspace serializes switches, so a native shortcut has one borrower.
final class SpaceShortcuts: Sendable {
  private let skyLight: SkyLight
  private let hotKeys: HotKeys

  init(skyLight: SkyLight, hotKeys: HotKeys) {
    self.skyLight = skyLight
    self.hotKeys = hotKeys
  }

  func switchSpace(to space: UInt64, on display: String, expecting: [DisplaySpaces]) async
    -> SpaceDispatch
  {
    guard DisplaySpaces.decode(skyLight.managedDisplaySpaces()) == expecting else {
      return .changed
    }
    guard let plan = SpaceRoute.plan(to: space, on: display, in: expecting) else {
      return .refused("macOS has no keyboard shortcut that reaches that Space from here.")
    }
    var expected = expecting
    for (press, arrivesAt) in plan {
      let result = await perform(press, to: arrivesAt, on: display, expecting: expected)
      guard result == .sent else { return result }
      expected = expected.map {
        $0.id == display
          ? DisplaySpaces(id: $0.id, currentSpace: arrivesAt, spaces: $0.spaces) : $0
      }
    }
    return .sent
  }

  @MainActor private func perform(
    _ press: SpaceRoute.Press, to space: UInt64, on display: String,
    expecting: [DisplaySpaces]
  ) async -> SpaceDispatch {
    let id: UInt32 =
      switch press {
      case .previous: 79
      case .next: 81
      case .desktop(let number): UInt32(117 + number)
      }
    guard let (key, flags) = skyLight.symbolicHotKey(id),
      let name = KeyCodes().name(of: key)
    else { return .refused("macOS has no keyboard shortcut for switching Spaces.") }
    let chord = Chord(
      Chord.Modifiers(CGEventFlags(rawValue: UInt64(flags))).subtracting(.function), name)
    guard hotKeys.release(chord) else {
      return .refused("macOS would not release Atelier's shortcut for switching Spaces.")
    }
    let wasEnabled = skyLight.isSymbolicHotKeyEnabled(id)
    var result: SpaceDispatch
    if wasEnabled || skyLight.setSymbolicHotKey(id, enabled: true) {
      let canRetry: Bool
      if case .desktop = press { canRetry = true } else { canRetry = false }
      result = await SpaceShortcutTransition(space: space, display: display, expecting: expecting)
        .run(
          displays: { DisplaySpaces.decode(self.skyLight.managedDisplaySpaces()) },
          post: { Self.post(key: key, flags: flags) }, canRetry: canRetry)
    } else {
      result = .refused("macOS would not enable its Space-switching shortcut.")
    }
    if !wasEnabled, !skyLight.setSymbolicHotKey(id, enabled: false) {
      result = .uncertain("macOS would not restore its disabled Space shortcut.")
    }
    if let reason = hotKeys.restore(chord) {
      result = .uncertain("Could not restore Atelier's shortcut: \(reason) Reload configuration.")
    }
    return result
  }

  private static func post(key: CGKeyCode, flags: UInt32) -> Bool {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
    else { return false }
    down.flags = CGEventFlags(rawValue: UInt64(flags))
    up.flags = []
    PostedKeys.mark(down)
    PostedKeys.mark(up)
    // Posting earlier combines these flags with physically held modifiers.
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
    return true
  }
}
