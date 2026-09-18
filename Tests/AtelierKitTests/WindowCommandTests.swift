import AtelierKit
import MacOS
import Testing

/// Selecting, cycling, and renumbering the current Desktop's windows.
@Suite struct WindowCommandTests {
  private let mac = FakeMac(
    focusedWindow: 1, windows: [window(1), window(2), window(3, onScreen: false)])

  @Test func selectingASlotFocusesExactlyThatWindow() async throws {
    let atelier = Atelier(mac)
    #expect(try await atelier.windows.select(2) == .changed)
    #expect(mac.focusedWindow == 2)
    #expect(try await atelier.slots() == [1, 2, 3])
  }

  @Test func selectingShowsAMinimizedOrHiddenWindow() async throws {
    let atelier = Atelier(mac)
    #expect(try await atelier.windows.select(3) == .changed)
    #expect(mac.focusedWindow == 3)
    guard case .desktop(let windows, _) = try await atelier.windows.list() else { return }
    #expect(windows.map(\.isVisible) == [true, true, true])
  }

  @Test func selectingTheFocusedWindowAsksNothingOfItsApp() async throws {
    #expect(try await Atelier(mac).windows.select(1) == .changed)
    #expect(mac.requests.isEmpty)
  }

  @Test func anEmptySlotIsNothingToDo() async throws {
    let atelier = Atelier(mac)
    #expect(try await atelier.windows.select(4) == .unchanged)
    #expect(try await atelier.windows.select(0) == .unchanged)
    #expect(try await Atelier(FakeMac()).windows.select(1) == .unchanged)
    #expect(mac.requests.isEmpty)
  }

  @Test func offADesktopEveryWindowCommandIsNothingToDo() async throws {
    let mac = FakeMac(
      activeSpace: 4, shownOnSecondDisplay: 4, focusedWindow: 1, windows: [window(1, on: [4])])
    let atelier = Atelier(mac)
    #expect(try await atelier.windows.select(1) == .unchanged)
    #expect(try await atelier.windows.cycle(.next) == .unchanged)
    #expect(try await atelier.windows.move(.by(1)) == .unchanged)
  }

  @Test func aDialogOrSheetKeepingTheKeyboardCountsAsFocused() async throws {
    mac.change { $0.modalWindow = 9 }
    #expect(try await Atelier(mac).windows.select(2) == .changed)
    #expect(mac.focusedWindow == 9)
  }

  @Test func aWindowThatClosedBeforeItCouldBeFocusedIsAFailure() async throws {
    // Still in the census the command works from, gone when its app is asked.
    mac.change { state in
      state.afterSnapshot = { $0.windows.removeAll { $0.id == 2 } }
    }
    await #expect(throws: AtelierError.failed("The selected window closed.")) {
      try await Atelier(mac).windows.select(2)
    }
  }

  @Test func aWindowThatWillNotTakeTheKeyboardIsAFailure() async throws {
    mac.change { $0.ignoresRaise = true }
    await #expect(throws: AtelierError.failed("Could not bring the window in App 2 forward.")) {
      try await Atelier(mac).windows.select(2)
    }
  }

  @Test func aFrozenAppFailsQuicklyAndKeepsItsSlot() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change { $0.frozenApps = [2] }
    await #expect(throws: AtelierError.failed("App 2 is not responding.")) {
      try await atelier.windows.select(2)
    }
    #expect(try await atelier.slots() == [1, 2, 3])
    // A healthy app's window is still one command away.
    #expect(try await atelier.windows.select(3) == .changed)
  }

  @Test func cyclingWraps() async throws {
    let atelier = Atelier(mac)
    #expect(try await atelier.windows.cycle(.previous) == .changed)
    #expect(mac.focusedWindow == 3)
    #expect(try await atelier.windows.cycle(.next) == .changed)
    #expect(mac.focusedWindow == 1)
    #expect(try await atelier.slots() == [1, 2, 3])
  }

  @Test func withNoListedWindowFocusedNextIsFirstAndPreviousIsLast() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change { $0.focusedWindow = nil }
    #expect(try await atelier.windows.cycle(.next) == .changed)
    #expect(mac.focusedWindow == 1)
    mac.change { $0.focusedWindow = nil }
    #expect(try await atelier.windows.cycle(.previous) == .changed)
    #expect(mac.focusedWindow == 3)
  }

  @Test func cyclingAnEmptyDesktopIsNothingToDo() async throws {
    #expect(try await Atelier(FakeMac()).windows.cycle(.next) == .unchanged)
  }

  @Test(arguments: [
    (WindowMove.by(1), [2, 1, 3, 4] as [UInt32]), (.by(2), [2, 3, 1, 4]), (.by(9), [2, 3, 4, 1]),
    (.toSlot(3), [2, 3, 1, 4]), (.toSlot(4), [2, 3, 4, 1]), (.toSlot(99), [2, 3, 4, 1]),
  ])
  func movingRenumbersOnlyTheList(move: WindowMove, expected: [UInt32]) async throws {
    let mac = FakeMac(focusedWindow: 1, windows: [window(1), window(2), window(3), window(4)])
    let atelier = Atelier(mac)
    #expect(try await atelier.windows.move(move) == .changed)
    #expect(try await atelier.slots() == expected)
    #expect(mac.focusedWindow == 1)
    #expect(mac.requests.isEmpty)
  }

  @Test func extremeMovesAreHeldWithinTheList() async throws {
    let mac = FakeMac(focusedWindow: 2, windows: [window(1), window(2), window(3)])
    let atelier = Atelier(mac)
    #expect(try await atelier.slots() == [2, 1, 3])
    #expect(try await atelier.windows.move(.by(.max)) == .changed)
    #expect(try await atelier.windows.move(.toSlot(.min)) == .changed)
    #expect(try await atelier.windows.move(.by(.min)) == .unchanged)
    #expect(try await atelier.windows.move(.toSlot(.max)) == .changed)
    #expect(try await atelier.slots() == [1, 3, 2])
  }

  @Test func movingEarlierStopsAtTheFirstSlot() async throws {
    let mac = FakeMac(focusedWindow: 3, windows: [window(3), window(1), window(2)])
    let atelier = Atelier(mac)
    #expect(try await atelier.windows.move(.by(-1)) == .unchanged)
    mac.change { $0.focusedWindow = 2 }
    #expect(try await atelier.windows.move(.by(-5)) == .changed)
    #expect(try await atelier.slots() == [2, 3, 1])
  }

  @Test func movingToTheSameSlotOrWithoutAListedWindowIsNothingToDo() async throws {
    let atelier = Atelier(mac)
    #expect(try await atelier.windows.move(.toSlot(1)) == .unchanged)
    #expect(try await atelier.windows.move(.by(0)) == .unchanged)
    mac.change { $0.focusedWindow = 9 }
    #expect(try await atelier.windows.move(.by(1)) == .unchanged)
  }

  @Test func commandsNeedAccessibility() async {
    mac.change { $0.hasAccessibility = false }
    await #expect(throws: AtelierError.accessibilityRequired) {
      try await Atelier(mac).windows.select(1)
    }
  }
}
