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
    #expect(try await Atelier(mac).slots() == [1, 5])
  }

  @Test func keepsMinimizedAndHiddenWindows() async throws {
    let mac = FakeMac(windows: [window(1, onScreen: false), window(2)])
    let list = try await Atelier(mac).windows.list()
    #expect(
      list
        == .desktop(
          [
            Window(id: 2, app: "App 2", title: "Window 2", isFocused: false, isVisible: true),
            Window(id: 1, app: "App 1", title: "Window 1", isFocused: false, isVisible: false),
          ], display: "first"))
  }

  @Test func startsWithTheFocusedThenVisibleFrontToBackThenTheRest() async throws {
    let mac = FakeMac(
      focusedWindow: 4,
      windows: [
        window(1, onScreen: false), window(2), window(3), window(4), window(5, onScreen: false),
      ])
    let atelier = Atelier(mac)
    #expect(try await atelier.slots() == [4, 2, 3, 1, 5])
    guard case .desktop(let windows, _) = try await atelier.windows.list() else { return }
    #expect(windows.map(\.isFocused) == [true, false, false, false, false])
  }

  @Test func aFocusedPanelLeavesFrontToBackOrder() async throws {
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2, ordinary: false)])
    #expect(try await Atelier(mac).slots() == [1])
  }

  @Test func followsTheFocusedWindowToAnotherDisplay() async throws {
    // WindowServer still calls Space 1 active, but the keyboard is in window 2.
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2, on: [3])])
    #expect(try await Atelier(mac).slots() == [2])
  }

  @Test func followsAFocusedPanelTheCensusLeavesOut() async throws {
    let mac = FakeMac(
      focusedWindow: 9, focusedWindowSpaces: [3], windows: [window(1), window(2, on: [3])])
    #expect(try await Atelier(mac).slots() == [2])
  }

  @Test func usesTheActiveSpaceWhenTheFocusedWindowIsElsewhere() async throws {
    // After switching to an empty Desktop the frontmost app's focused window
    // is on a Desktop no display is showing.
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2, on: [2])])
    #expect(try await Atelier(mac).slots() == [1])
  }

  @Test func usesTheActiveSpaceWhenTheFocusedWindowIsOnEveryDesktop() async throws {
    let mac = FakeMac(
      activeSpace: 3, focusedWindow: 1, windows: [window(1, on: [1, 2, 3]), window(2, on: [3])])
    #expect(try await Atelier(mac).slots() == [1, 2])
  }

  @Test(arguments: [4, 5] as [UInt64])
  func fullScreenAndSplitViewSpacesHaveNoList(space: UInt64) async throws {
    let mac = FakeMac(
      activeSpace: space, shownOnSecondDisplay: space, focusedWindow: 1,
      windows: [window(1, on: [space]), window(2)])
    #expect(try await Atelier(mac).windows.list() == .notDesktop)
  }

  @Test func failsWithoutAccessibility() async {
    let mac = FakeMac(hasAccessibility: false, windows: [window(1)])
    await #expect(throws: AtelierError.accessibilityRequired) {
      try await Atelier(mac).windows.list()
    }
  }

  @Test func failsWhenMacOSRefusesTheCensus() async {
    await #expect(throws: AtelierError.unavailable) {
      try await Atelier(FakeMac(refusesCensus: true)).windows.list()
    }
  }

  @Test func failsWhenTheCurrentSpaceIsUnknown() async {
    await #expect(throws: AtelierError.unavailable) {
      try await Atelier(FakeMac(activeSpace: 99)).windows.list()
    }
  }
}

@Suite struct WindowListHoldTests {
  @Test func reportsWhenTheModifiersAreHeldShiftTolerated() async throws {
    let mac = FakeMac()
    let atelier = Atelier(mac)
    await atelier.config.ready()
    var windows = atelier.holds.changes().map(\.windows).makeAsyncIterator()
    mac.hold([.command, .option])
    #expect(await windows.next() == true)
    mac.hold([.command, .option, .shift])
    mac.hold([.command, .option, .control])
    #expect(await windows.next() == false)
    mac.hold([.command, .option])
    #expect(await windows.next() == true)
    mac.hold([.command, .option, .function])
    #expect(await windows.next() == false)
    mac.hold([.command, .option])
    #expect(await windows.next() == true)
    mac.hold([])
    #expect(await windows.next() == false)
  }

  @Test func theWindowListNamesItsDisplay() async throws {
    let atelier = Atelier(FakeMac(windows: [window(1)]))
    guard case .desktop(let windows, let display) = try await atelier.windows.list() else {
      Issue.record("No list")
      return
    }
    #expect(windows.map(\.id) == [1])
    #expect(display == "first")
  }
}
