import AtelierKit
import MacOS
import Testing

/// Selecting, cycling, and renumbering the current Desktop's windows.
@Suite struct WindowCommandTests {
  private let mac = FakeMac(
    focusedWindow: 1, windows: [window(1), window(2), window(3, onScreen: false)])

  @Test func selectingASlotFocusesExactlyThatWindow() async throws {
    let session = Session(mac)
    #expect(try await session.windows.select(2) == .done)
    #expect(mac.focusedWindow == 2)
    #expect(try await session.slots() == [1, 2, 3])
  }

  @Test func selectingShowsAMinimizedOrHiddenWindow() async throws {
    let session = Session(mac)
    #expect(try await session.windows.select(3) == .done)
    #expect(mac.focusedWindow == 3)
    guard case .desktop(let windows) = try await session.windows.list() else { return }
    #expect(windows.map(\.isVisible) == [true, true, true])
  }

  @Test func selectingTheFocusedWindowAsksNothingOfItsApp() async throws {
    #expect(try await Session(mac).windows.select(1) == .done)
    #expect(mac.requests.isEmpty)
  }

  @Test func anEmptySlotIsNothingToDo() async throws {
    let session = Session(mac)
    #expect(try await session.windows.select(4) == .noop)
    #expect(try await session.windows.select(0) == .noop)
    #expect(try await Session(FakeMac()).windows.select(1) == .noop)
    #expect(mac.requests.isEmpty)
  }

  @Test func offADesktopEveryWindowCommandIsNothingToDo() async throws {
    let mac = FakeMac(
      activeSpace: 4, shownOnSecondDisplay: 4, focusedWindow: 1, windows: [window(1, on: [4])])
    let session = Session(mac)
    #expect(try await session.windows.select(1) == .noop)
    #expect(try await session.windows.cycle(.next) == .noop)
    #expect(try await session.windows.move(.by(1)) == .noop)
  }

  @Test func aDialogOrSheetKeepingTheKeyboardCountsAsFocused() async throws {
    mac.change { $0.modalWindow = 9 }
    #expect(try await Session(mac).windows.select(2) == .done)
    #expect(mac.focusedWindow == 9)
  }

  @Test func aWindowThatClosedBeforeItCouldBeFocusedIsAFailure() async throws {
    // Still in the census the command works from, gone when its app is asked.
    mac.change { state in
      state.afterSnapshot = { $0.windows.removeAll { $0.id == 2 } }
    }
    await #expect(throws: AtelierError.failed("The selected window closed.")) {
      try await Session(mac).windows.select(2)
    }
  }

  @Test func aWindowThatWillNotTakeTheKeyboardIsAFailure() async throws {
    mac.change { $0.ignoresRaise = true }
    await #expect(throws: AtelierError.failed("Could not bring the window in App 2 forward.")) {
      try await Session(mac).windows.select(2)
    }
  }

  @Test func aFrozenAppFailsQuicklyAndKeepsItsSlot() async throws {
    let session = Session(mac)
    _ = try await session.slots()
    mac.change { $0.frozenApps = [2] }
    await #expect(throws: AtelierError.failed("App 2 is not responding.")) {
      try await session.windows.select(2)
    }
    #expect(try await session.slots() == [1, 2, 3])
    // A healthy app's window is still one command away.
    #expect(try await session.windows.select(3) == .done)
  }

  @Test func cyclingWraps() async throws {
    let session = Session(mac)
    #expect(try await session.windows.cycle(.previous) == .done)
    #expect(mac.focusedWindow == 3)
    #expect(try await session.windows.cycle(.next) == .done)
    #expect(mac.focusedWindow == 1)
    #expect(try await session.slots() == [1, 2, 3])
  }

  @Test func withNoListedWindowFocusedNextIsFirstAndPreviousIsLast() async throws {
    let session = Session(mac)
    _ = try await session.slots()
    mac.change { $0.focusedWindow = nil }
    #expect(try await session.windows.cycle(.next) == .done)
    #expect(mac.focusedWindow == 1)
    mac.change { $0.focusedWindow = nil }
    #expect(try await session.windows.cycle(.previous) == .done)
    #expect(mac.focusedWindow == 3)
  }

  @Test func cyclingAnEmptyDesktopIsNothingToDo() async throws {
    #expect(try await Session(FakeMac()).windows.cycle(.next) == .noop)
  }

  @Test(arguments: [
    (WindowMove.by(1), [2, 1, 3, 4] as [UInt32]), (.by(2), [2, 3, 1, 4]), (.by(9), [2, 3, 4, 1]),
    (.toSlot(3), [2, 3, 1, 4]), (.toSlot(4), [2, 3, 4, 1]), (.toSlot(99), [2, 3, 4, 1]),
  ])
  func movingRenumbersOnlyTheList(move: WindowMove, expected: [UInt32]) async throws {
    let mac = FakeMac(focusedWindow: 1, windows: [window(1), window(2), window(3), window(4)])
    let session = Session(mac)
    #expect(try await session.windows.move(move) == .done)
    #expect(try await session.slots() == expected)
    #expect(mac.focusedWindow == 1)
    #expect(mac.requests.isEmpty)
  }

  @Test func extremeMovesAreHeldWithinTheList() async throws {
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2), window(3)])
    let session = Session(mac)
    #expect(try await session.slots() == [2, 1, 3])
    #expect(try await session.windows.move(.by(.max)) == .done)
    #expect(try await session.windows.move(.toSlot(.min)) == .done)
    #expect(try await session.windows.move(.by(.min)) == .noop)
    #expect(try await session.windows.move(.toSlot(.max)) == .done)
    #expect(try await session.slots() == [1, 3, 2])
  }

  @Test func movingEarlierStopsAtTheFirstSlot() async throws {
    let mac = FakeMac(focusedWindow: 3, windows: [window(3), window(1), window(2)])
    let session = Session(mac)
    #expect(try await session.windows.move(.by(-1)) == .noop)
    mac.change { $0.focusedWindow = 2 }
    #expect(try await session.windows.move(.by(-5)) == .done)
    #expect(try await session.slots() == [2, 3, 1])
  }

  @Test func movingToTheSameSlotOrWithoutAListedWindowIsNothingToDo() async throws {
    let session = Session(mac)
    #expect(try await session.windows.move(.toSlot(1)) == .noop)
    #expect(try await session.windows.move(.by(0)) == .noop)
    mac.change { $0.focusedWindow = 9 }
    #expect(try await session.windows.move(.by(1)) == .noop)
  }

  @Test func commandsNeedAccessibility() async {
    mac.change { $0.hasAccessibility = false }
    await #expect(throws: AtelierError.accessibilityRequired) {
      try await Session(mac).windows.select(1)
    }
  }
}
