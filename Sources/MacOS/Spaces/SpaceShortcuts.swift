import CoreGraphics
import Foundation
import Synchronization

/// Switches Spaces by pressing macOS's own shortcuts, so Dock switches exactly
/// as it does for the user. Asking WindowServer to change Space directly
/// leaves Dock behind: the old Space's windows and menu bar stay on screen.
///
/// A shortcut the user has turned off is turned on for this login session
/// just long enough for macOS to match the key press, then off again. The
/// user's saved setting is never written. Should Atelier die in that moment
/// the shortcut stays on until logout.
final class SpaceShortcuts: Sendable {
  /// macOS matches a press within a few milliseconds; the switch that follows
  /// takes longer, and does not need the shortcut.
  static let borrowTime: TimeInterval = 0.3

  /// How long one press may take to show, animation included.
  static let pressTimeLimit: Duration = .seconds(3)

  private let skyLight: SkyLight
  /// Shortcuts to turn off again, and how many presses are still borrowing them.
  private let borrowed = Mutex<[UInt32: Int]>([:])

  init(skyLight: SkyLight) {
    self.skyLight = skyLight
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
    for (press, arrivesAt) in plan {
      guard self.press(press) else {
        return .refused("macOS has no keyboard shortcut for switching Spaces.")
      }
      let deadline = ContinuousClock.now + Self.pressTimeLimit
      while currentSpace(of: display) != arrivesAt {
        guard ContinuousClock.now < deadline else {
          return .uncertain("macOS did not switch to the Space Atelier asked for.")
        }
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
    return .sent
  }

  private func currentSpace(of display: String) -> UInt64? {
    DisplaySpaces.decode(skyLight.managedDisplaySpaces()).first { $0.id == display }?
      .currentSpace
  }

  private func press(_ press: SpaceRoute.Press) -> Bool {
    // Numbers in macOS's table of its own keyboard shortcuts.
    let id: UInt32 =
      switch press {
      case .previous: 79
      case .next: 81
      case .desktop(let number): UInt32(117 + number)
      }
    guard let (key, flags) = skyLight.symbolicHotKey(id),
      let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false),
      borrow(id)
    else { return false }
    down.flags = CGEventFlags(rawValue: UInt64(flags))
    up.flags = []
    // Marked as Atelier's own, so its key listener lets them through.
    PostedKeys.mark(down)
    PostedKeys.mark(up)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }

  /// False when a shortcut that is off could not be turned on.
  private func borrow(_ id: UInt32) -> Bool {
    let mustReturn: Bool? = borrowed.withLock { borrowed in
      if let presses = borrowed[id] {
        borrowed[id] = presses + 1
        return true
      }
      if skyLight.isSymbolicHotKeyEnabled(id) { return false }
      guard skyLight.setSymbolicHotKey(id, enabled: true) else { return nil }
      borrowed[id] = 1
      return true
    }
    guard let mustReturn else { return false }
    guard mustReturn else { return true }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.borrowTime) { [self] in
      borrowed.withLock { borrowed in
        guard let presses = borrowed[id] else { return }
        borrowed[id] = presses > 1 ? presses - 1 : nil
        if presses == 1 { _ = skyLight.setSymbolicHotKey(id, enabled: false) }
      }
    }
    return true
  }
}
