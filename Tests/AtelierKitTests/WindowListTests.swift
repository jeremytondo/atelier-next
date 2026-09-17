import AtelierKit
import MacOS
import Testing

@Suite struct WindowListTests {
  private func ids(_ mac: FakeMac, in context: FocusContext? = nil) async throws -> [UInt32]? {
    guard case .desktop(let windows) = try await Session(mac: mac).windows.list(in: context)
    else { return nil }
    return windows.map(\.id)
  }

  @Test func listsOrdinaryWindowsOfTheCurrentDesktopOnly() async throws {
    let mac = FakeMac(windows: [
      window(1), window(2, on: [2]), window(3, ordinary: false), window(4, on: [3]),
      window(5, on: [1, 2, 3]),
    ])
    #expect(try await ids(mac) == [1, 5])
  }

  @Test func keepsMinimizedAndHiddenWindows() async throws {
    let mac = FakeMac(windows: [window(1, onScreen: false), window(2)])
    let list = try await Session(mac: mac).windows.list()
    #expect(
      list
        == .desktop([
          Window(id: 2, app: "App 2", title: "Window 2", isFocused: false, isVisible: true),
          Window(id: 1, app: "App 1", title: "Window 1", isFocused: false, isVisible: false),
        ]))
  }

  @Test func ordersFocusedThenVisibleFrontToBackThenTheRest() async throws {
    let mac = FakeMac(
      focusedWindow: 4,
      windows: [
        window(1, onScreen: false), window(2), window(3), window(4), window(5, onScreen: false),
      ])
    #expect(try await ids(mac) == [4, 2, 3, 1, 5])
    let list = try await Session(mac: mac).windows.list()
    guard case .desktop(let windows) = list else { return }
    #expect(windows.map(\.isFocused) == [true, false, false, false, false])
  }

  @Test func aFocusedPanelLeavesFrontToBackOrder() async throws {
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2, ordinary: false)])
    #expect(try await ids(mac) == [1])
  }

  @Test func followsTheFocusedWindowToAnotherDisplay() async throws {
    // WindowServer still calls Space 1 active, but the keyboard is in window 2.
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2, on: [3])])
    #expect(try await ids(mac) == [2])
  }

  @Test func followsAFocusedPanelTheCensusLeavesOut() async throws {
    let mac = FakeMac(
      focusedWindow: 9, focusedWindowSpaces: [3], windows: [window(1), window(2, on: [3])])
    #expect(try await ids(mac) == [2])
  }

  @Test func usesTheActiveSpaceWhenTheFocusedWindowIsElsewhere() async throws {
    // After switching to an empty Desktop the frontmost app's focused window
    // is on a Desktop no display is showing.
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2, on: [2])])
    #expect(try await ids(mac) == [1])
  }

  @Test func usesTheActiveSpaceWhenTheFocusedWindowIsOnEveryDesktop() async throws {
    let mac = FakeMac(
      activeSpace: 3, focusedWindow: 1, windows: [window(1, on: [1, 2, 3]), window(2, on: [3])])
    #expect(try await ids(mac) == [1, 2])
  }

  @Test(arguments: [4, 5] as [UInt64])
  func reportsFullScreenAndSplitViewSpacesAsNotDesktops(space: UInt64) async throws {
    let mac = FakeMac(
      activeSpace: space, shownOnSecondDisplay: space, focusedWindow: 1,
      windows: [window(1, on: [space]), window(2)])
    #expect(try await Session(mac: mac).windows.list() == .notDesktop)
  }

  @Test func keepsTheContextFromBeforeAtelierTookFocus() async throws {
    var mac = FakeMac(
      focusedWindow: 2, windows: [window(1), window(2, on: [3]), window(3, on: [3])])
    let context = await Session(mac: mac).windows.context()
    // The popover opens: Atelier is frontmost and the first display is active.
    mac.focusedWindow = nil
    #expect(try await ids(mac) == [1])
    // The snapshot itself is still fresh.
    mac.windows.append(window(4, on: [3]))
    #expect(try await ids(mac, in: context) == [2, 3, 4])
  }

  @Test func failsWithoutAccessibility() async {
    let mac = FakeMac(hasAccessibility: false, windows: [window(1)])
    await #expect(throws: WindowListError.accessibilityRequired) {
      try await Session(mac: mac).windows.list()
    }
  }

  @Test func failsWhenMacOSRefusesTheCensus() async {
    await #expect(throws: WindowListError.unavailable) {
      try await Session(mac: FakeMac(refusesCensus: true)).windows.list()
    }
  }

  @Test func failsWhenTheCurrentSpaceIsUnknown() async {
    await #expect(throws: WindowListError.unavailable) {
      try await Session(mac: FakeMac(activeSpace: 99)).windows.list()
    }
  }
}
