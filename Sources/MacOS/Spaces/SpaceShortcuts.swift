import CoreGraphics
import Foundation

/// Switches to Desktops by pressing macOS's own shortcuts, so Dock switches exactly
/// as it does for the user. Asking WindowServer to change Space directly
/// leaves Dock behind: the old Space's windows and menu bar stay on screen.
///
/// A shortcut the user has turned off is turned on for this login session
/// until the switch shows, then off again. The user's saved setting is never
/// written. Should Atelier die in that moment the shortcut stays on until
/// logout. Commands run one at a time, so no two presses share a shortcut.
///
/// Atelier may bind the very chord macOS switches with, and a chord Atelier
/// has registered never reaches Dock, so it is lent to macOS for the press.
final class SpaceShortcuts: Sendable {
  private let skyLight: SkyLight
  private let hotKeys: HotKeys

  init(skyLight: SkyLight, hotKeys: HotKeys) {
    self.skyLight = skyLight
    self.hotKeys = hotKeys
  }

  /// Each press waits for the last to show, since the next one counts from there.
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
    _ press: SpaceRoute.Press, to space: UInt64, on display: String, expecting: [DisplaySpaces]
  ) async -> SpaceDispatch {
    // Numbers in macOS's table of its own keyboard shortcuts.
    let id: UInt32 =
      switch press {
      case .previous: 79
      case .next: 81
      case .desktop(let number): UInt32(117 + number)
      }
    guard let (key, flags) = skyLight.symbolicHotKey(id), let name = KeyCodes().name(of: key)
    else { return .refused("macOS has no keyboard shortcut for switching Spaces.") }
    // macOS lists Fn on its arrow-key shortcuts, which no chord of Atelier's carries.
    let chord = Chord(
      Chord.Modifiers(CGEventFlags(rawValue: UInt64(flags))).subtracting(.function), name)
    guard hotKeys.lend(chord) else {
      return .refused("macOS would not release Atelier's shortcut for switching Spaces.")
    }
    let wasEnabled = skyLight.isSymbolicHotKeyEnabled(id)
    var result: SpaceDispatch
    if wasEnabled || skyLight.setSymbolicHotKey(id, enabled: true) {
      // A jump to a numbered Desktop lands in the same place however often it
      // is pressed; a step does not.
      let isJump = if case .desktop = press { true } else { false }
      result = await SpaceShortcutTransition(space: space, display: display, expecting: expecting)
        .run(
          displays: { DisplaySpaces.decode(self.skyLight.managedDisplaySpaces()) },
          post: { Self.post(key: key, flags: flags) }, canRetry: isJump)
      if !wasEnabled, !skyLight.setSymbolicHotKey(id, enabled: false) {
        result = .uncertain("macOS would not turn its Space-switching shortcut off again.")
      }
    } else {
      result = .refused("macOS would not turn its Space-switching shortcut on.")
    }
    if let reason = hotKeys.reclaim() {
      result = .uncertain(
        "Atelier's own shortcut on those keys could not be registered again. \(reason) Reloading the configuration registers it."
      )
    }
    return result
  }

  private static func post(key: CGKeyCode, flags: UInt32) -> Bool {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
    else { return false }
    down.flags = CGEventFlags(rawValue: UInt64(flags))
    up.flags = []
    // Marked as Atelier's own, so its key listener lets them through.
    PostedKeys.mark(down)
    PostedKeys.mark(up)
    // Posted where macOS has finished with the keyboard itself. Posted any
    // earlier, the press takes on whatever modifiers are held at that moment,
    // so Control-2 sent while Option is down arrives as Control-Option-2, which
    // is no shortcut of macOS's, and nothing switches. A shortcut of Atelier's
    // is pressed with its modifiers held, so that is the usual case.
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
    return true
  }
}
