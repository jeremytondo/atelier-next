import CoreGraphics
import Foundation

/// Switches Spaces by pressing macOS's own shortcuts, so Dock switches exactly
/// as it does for the user. Asking WindowServer to change Space directly
/// leaves Dock behind: the old Space's windows and menu bar stay on screen.
///
/// Only a shortcut that is switched on in Keyboard settings is pressed. One
/// that is off can be switched on for the login session, and macOS says it
/// is on, yet pressing it then does nothing, so there is no borrowing: a
/// route uses the shortcuts the user has, and with "Switch to Desktop N" off
/// a far Desktop is reached a step at a time.
final class SpaceShortcuts: Sendable {
  /// How long one press may take to show, animation included.
  static let pressTimeLimit: Duration = .seconds(3)

  /// How long a press waits for the user to let go of the keys that called for it.
  static let releaseTimeLimit: Duration = .seconds(2)

  private let skyLight: SkyLight

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
    let plan = SpaceRoute.plan(to: space, on: display, in: expecting) { [skyLight] press in
      skyLight.isSymbolicHotKeyEnabled(Self.id(of: press))
    }
    guard let plan else {
      return .refused(
        "macOS has no keyboard shortcut switched on that reaches that Space from here. Turn on Mission Control's shortcuts in Keyboard settings."
      )
    }
    for (press, arrivesAt) in plan {
      guard let (key, table) = skyLight.symbolicHotKey(Self.id(of: press)) else {
        return .refused("macOS has no keyboard shortcut for switching Spaces.")
      }
      let flags = CGEventFlags(rawValue: UInt64(table))
      guard await fingersAreOff(allBut: flags) else {
        return .refused("Let go of the modifier keys, and Atelier will switch Spaces.")
      }
      guard self.press(key, flags) else {
        return .refused("macOS would not take a key press from Atelier.")
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

  /// The press's number in macOS's table of its own keyboard shortcuts.
  private static func id(of press: SpaceRoute.Press) -> UInt32 {
    switch press {
    case .previous: 79
    case .next: 81
    case .desktop(let number): UInt32(117 + number)
    }
  }

  /// Waits for every modifier key the shortcut does not use to come up. macOS
  /// adds whatever modifiers are down to a press, so Control+Right pressed
  /// while the user still holds Option, as after Option+2, is Control+Option+
  /// Right: no Space shortcut, and one of Atelier's own. A key posted as
  /// released stays down while a finger holds it, so there is only waiting.
  /// False when they are still down after `releaseTimeLimit`.
  private func fingersAreOff(allBut flags: CGEventFlags) async -> Bool {
    let others = Self.modifierKeys.reduce(into: CGEventFlags()) { $0.insert($1.flag) }
      .subtracting(flags)
    let deadline = ContinuousClock.now + Self.releaseTimeLimit
    while !CGEventSource.flagsState(.combinedSessionState).intersection(others).isEmpty {
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return true
  }

  private func press(_ key: CGKeyCode, _ flags: CGEventFlags) -> Bool {
    // macOS matches its own shortcuts against the keyboard's live modifier
    // state, which only a modifier key's own event changes. A key press that
    // merely carries the flags is ignored whenever that state lacks them, so
    // each modifier key goes down first and comes up afterwards, as it would
    // under a finger.
    let modifiers = Self.modifierKeys.filter { flags.contains($0.flag) }
    var held: CGEventFlags = []
    var presses: [(CGKeyCode, Bool, CGEventFlags)] = modifiers.map {
      held.insert($0.flag)
      return ($0.key, true, held)
    }
    presses += [(key, true, flags), (key, false, flags)]
    presses += modifiers.reversed().map {
      held.remove($0.flag)
      return ($0.key, false, held)
    }
    let events = presses.compactMap { key, isDown, flags -> CGEvent? in
      let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: isDown)
      event?.flags = flags
      return event
    }
    guard events.count == presses.count else { return false }
    for event in events {
      // Marked as Atelier's own, so its key listener lets them through.
      PostedKeys.mark(event)
      event.post(tap: .cghidEventTap)
    }
    return true
  }

  /// The modifier keys a shortcut can need, by the left-hand key of each.
  private static let modifierKeys: [(flag: CGEventFlags, key: CGKeyCode)] = [
    (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55),
  ]
}
