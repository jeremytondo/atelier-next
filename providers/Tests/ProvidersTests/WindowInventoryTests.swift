import Testing

@testable import Providers

private func window(
  _ id: UInt32, pid: Int32 = 42, spaces: [String] = ["1"], onScreen: Bool = false
) -> Snapshot.Window {
  Snapshot.Window(
    id: id, pid: pid, launched: 1, app: "Fixture", bundleID: "fixture", title: "",
    spaces: spaces, onScreen: onScreen, ordinary: nil)
}

@Test func closedWindowServerObjectsAreRemovedWithoutLosingHiddenOrInactiveWindows() {
  let census = [
    window(1),  // Closed, but WindowServer retains the object and membership.
    window(2),  // Hidden or minimized, still in AXWindows.
    window(3, spaces: ["2"]),  // Inactive Desktop, absent from AXWindows.
    window(4, spaces: []),  // Unknown membership is inconclusive.
    window(5, onScreen: true),  // Visible evidence wins over a partial AX reply.
    window(6, spaces: ["1", "2"]),  // Closed All Desktops window.
    window(7, spaces: ["3"]),  // Closed on the second display's active Desktop.
  ]
  let remaining = WindowInventory.excludingClosed(
    census, accessible: [42: [2]], activeSpaces: ["1", "3"])
  #expect(remaining.map(\.id) == [2, 3, 4, 5])
}

@Test func failedAccessibilityReadsAndDesktopTransitionsDoNotProveClosure() {
  let census = [window(1), window(2, pid: 43)]
  // Missing dictionary entries represent a refused AX read or an unreadable window ID.
  #expect(
    WindowInventory.excludingClosed(census, accessible: [:], activeSpaces: ["1"])
      .map(\.id) == [1, 2])
  // An empty successful read proves this app's windows closed, not another app's.
  #expect(
    WindowInventory.excludingClosed(census, accessible: [42: []], activeSpaces: ["1"])
      .map(\.id) == [2])
  // No stable active Spaces, as during a switch or a failed topology read.
  #expect(
    WindowInventory.excludingClosed(census, accessible: [42: [], 43: []], activeSpaces: [])
      .map(\.id) == [1, 2])
}
