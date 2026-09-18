import AtelierKit
import MacOS
import Testing

/// Which windows are listed, for which Desktop, and how a list starts.
@Suite struct WindowListTests {
  @Test func listsOrdinaryWindowsOfTheCurrentDesktopOnly() async throws {
    let mac = FakeMac(windows: [
      window(1), window(2, on: [2]), window(3, ordinary: false), window(4, on: [3]),
      window(5, on: [1, 2, 3]),
    ])
    #expect(try await Session(mac).slots() == [1, 5])
  }

  @Test func keepsMinimizedAndHiddenWindows() async throws {
    let mac = FakeMac(windows: [window(1, onScreen: false), window(2)])
    let list = try await Session(mac).windows.list()
    #expect(
      list
        == .desktop([
          Window(id: 2, app: "App 2", title: "Window 2", isFocused: false, isVisible: true),
          Window(id: 1, app: "App 1", title: "Window 1", isFocused: false, isVisible: false),
        ]))
  }

  @Test func startsWithTheFocusedThenVisibleFrontToBackThenTheRest() async throws {
    let mac = FakeMac(
      focusedWindow: 4,
      windows: [
        window(1, onScreen: false), window(2), window(3), window(4), window(5, onScreen: false),
      ])
    let session = Session(mac)
    #expect(try await session.slots() == [4, 2, 3, 1, 5])
    guard case .desktop(let windows) = try await session.windows.list() else { return }
    #expect(windows.map(\.isFocused) == [true, false, false, false, false])
  }

  @Test func aFocusedPanelLeavesFrontToBackOrder() async throws {
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2, ordinary: false)])
    #expect(try await Session(mac).slots() == [1])
  }

  @Test func followsTheFocusedWindowToAnotherDisplay() async throws {
    // WindowServer still calls Space 1 active, but the keyboard is in window 2.
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2, on: [3])])
    #expect(try await Session(mac).slots() == [2])
  }

  @Test func followsAFocusedPanelTheCensusLeavesOut() async throws {
    let mac = FakeMac(
      focusedWindow: 9, focusedWindowSpaces: [3], windows: [window(1), window(2, on: [3])])
    #expect(try await Session(mac).slots() == [2])
  }

  @Test func usesTheActiveSpaceWhenTheFocusedWindowIsElsewhere() async throws {
    // After switching to an empty Desktop the frontmost app's focused window
    // is on a Desktop no display is showing.
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2, on: [2])])
    #expect(try await Session(mac).slots() == [1])
  }

  @Test func usesTheActiveSpaceWhenTheFocusedWindowIsOnEveryDesktop() async throws {
    let mac = FakeMac(
      activeSpace: 3, focusedWindow: 1, windows: [window(1, on: [1, 2, 3]), window(2, on: [3])])
    #expect(try await Session(mac).slots() == [1, 2])
  }

  @Test(arguments: [4, 5] as [UInt64])
  func fullScreenAndSplitViewSpacesHaveNoList(space: UInt64) async throws {
    let mac = FakeMac(
      activeSpace: space, shownOnSecondDisplay: space, focusedWindow: 1,
      windows: [window(1, on: [space]), window(2)])
    #expect(try await Session(mac).windows.list() == .notDesktop)
  }

  @Test func keepsTheContextFromBeforeAtelierTookFocus() async throws {
    let mac = FakeMac(
      focusedWindow: 2, windows: [window(1), window(2, on: [3]), window(3, on: [3])])
    let session = Session(mac)
    let context = await session.windows.context()
    // The popover opens: Atelier is frontmost and the first display is active.
    mac.change { $0.focusedWindow = nil }
    #expect(try await session.slots() == [1])
    // The census itself is still fresh.
    mac.change { $0.windows.append(window(4, on: [3])) }
    guard case .desktop(let windows) = try await session.windows.list(in: context) else {
      Issue.record("Expected a Desktop")
      return
    }
    #expect(windows.map(\.id) == [2, 3, 4])
    #expect(windows.map(\.isFocused) == [true, false, false])
  }

  @Test func failsWithoutAccessibility() async {
    let mac = FakeMac(hasAccessibility: false, windows: [window(1)])
    await #expect(throws: AtelierError.accessibilityRequired) {
      try await Session(mac).windows.list()
    }
  }

  @Test func failsWhenMacOSRefusesTheCensus() async {
    await #expect(throws: AtelierError.unavailable) {
      try await Session(FakeMac(refusesCensus: true)).windows.list()
    }
  }

  @Test func failsWhenTheCurrentSpaceIsUnknown() async {
    await #expect(throws: AtelierError.unavailable) {
      try await Session(FakeMac(activeSpace: 99)).windows.list()
    }
  }
}
