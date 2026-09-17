import Foundation
import MacOS

/// A Mac with two displays: Desktops 1 and 2 on the first, showing 1, and
/// Desktop 3 beside full-screen Space 4 and Split View Space 5 on the second,
/// showing 3.
struct FakeMac: Mac {
  var hasAccessibility = true
  var activeSpace: UInt64 = 1
  var shownOnSecondDisplay: UInt64 = 3
  /// Nil while Atelier itself is frontmost. It need not be in `windows`: a
  /// panel can have the keyboard.
  var focusedWindow: UInt32?
  var focusedWindowSpaces: [UInt64]?
  var windows: [WindowFacts] = []
  var refusesCensus = false

  func requestAccessibility() {}

  func focus() async -> Focus {
    let spaces = focusedWindowSpaces ?? windows.first { $0.id == focusedWindow }?.spaces ?? []
    return Focus(window: focusedWindow, windowSpaces: spaces, activeSpace: activeSpace)
  }

  func snapshot() async -> Snapshot? {
    guard !refusesCensus else { return nil }
    return Snapshot(
      displays: [
        DisplaySpaces(
          currentSpace: 1,
          spaces: [Space(id: 1, isDesktop: true), Space(id: 2, isDesktop: true)]),
        DisplaySpaces(
          currentSpace: shownOnSecondDisplay,
          spaces: [
            Space(id: 3, isDesktop: true), Space(id: 4, isDesktop: false),
            Space(id: 5, isDesktop: false),
          ]),
      ],
      windows: windows)
  }
}

func window(
  _ id: UInt32, on spaces: [UInt64] = [1], onScreen: Bool = true, ordinary: Bool = true
) -> WindowFacts {
  WindowFacts(
    id: id, app: "App \(id)", title: "Window \(id)", spaces: spaces, isOnScreen: onScreen,
    isOrdinary: ordinary)
}
