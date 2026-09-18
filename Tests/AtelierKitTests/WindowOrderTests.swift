import AtelierKit
import Foundation
import MacOS
import Testing

/// What changes a list once it exists, and what must not.
@Suite struct WindowOrderTests {
  private let mac = FakeMac(focusedWindow: 1, windows: [window(1), window(2), window(3)])

  @Test func focusChangesDoNotReorder() async throws {
    let atelier = Atelier(mac)
    #expect(try await atelier.slots() == [1, 2, 3])
    mac.change {
      $0.focusedWindow = 3
      $0.windows = [window(3), window(1), window(2)]
    }
    #expect(try await atelier.slots() == [1, 2, 3])
  }

  @Test func arrivalsAppendAndClosuresCloseRanks() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change { $0.windows = [window(4), window(1), window(3)] }
    #expect(try await atelier.slots() == [1, 3, 4])
  }

  @Test func aWindowThatLeavesAndReturnsGoesToTheEnd() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change { $0.windows[0] = window(1, on: [2]) }
    #expect(try await atelier.slots() == [2, 3])
    mac.change { $0.windows[0] = window(1) }
    #expect(try await atelier.slots() == [2, 3, 1])
  }

  @Test func aWindowOnTwoDesktopsHasAPlaceInEach() async throws {
    let mac = FakeMac(windows: [window(1, on: [1, 2]), window(2), window(3, on: [2])])
    let atelier = Atelier(mac)
    #expect(try await atelier.slots() == [1, 2])
    mac.change { $0.windows.insert(window(4, on: [2]), at: 0) }
    mac.change { $0.show(2) }
    #expect(try await atelier.slots() == [1, 3, 4])
  }

  @Test func aFrozenAppKeepsItsSlots() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change { $0.frozenApps = [2] }
    #expect(try await atelier.slots() == [1, 2, 3])
  }

  @Test func aNewWindowWaitsUntilItsAppConfirmsItIsOrdinary() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change {
      $0.frozenApps = [4]
      $0.windows.append(window(4))
    }
    #expect(try await atelier.slots() == [1, 2, 3])
    mac.change { $0.frozenApps = [] }
    #expect(try await atelier.slots() == [1, 2, 3, 4])
  }

  @Test func unknownMembershipIsNotADeparture() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change { $0.windows[1] = window(2, on: []) }
    #expect(try await atelier.slots() == [1, 2, 3])
  }

  @Test func aRefusedCensusChangesNothing() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change {
      $0.refusesCensus = true
      $0.windows = []
    }
    await #expect(throws: AtelierError.unavailable) { try await atelier.slots() }
    mac.change {
      $0.refusesCensus = false
      $0.windows = [window(3), window(2), window(1)]
    }
    #expect(try await atelier.slots() == [1, 2, 3])
  }

  @Test func aWindowItsAppNoLongerListsHasClosed() async throws {
    // WindowServer can keep a closed window listed, off screen.
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change { $0.windows[1] = window(2, onScreen: false).with(report: .missing) }
    #expect(try await atelier.slots() == [1, 3])
  }

  @Test func switchingNativeTabsRemovesTheInactiveTab() async throws {
    let atelier = Atelier(mac)
    #expect(try await atelier.slots() == [1, 2, 3])
    // Ghostty retains the old tab in WindowServer, without Space membership,
    // while Accessibility lists only the selected tab.
    mac.change {
      $0.windows[0] = window(1, on: [], onScreen: false).with(report: .missing)
      $0.windows.append(window(4).with(app: 1))
      $0.focusedWindow = 4
    }
    #expect(try await atelier.slots() == [2, 3, 4])
    #expect(try await atelier.windows.select(1) == .changed)
    #expect(mac.focusedWindow == 2)
    #expect(try await atelier.windows.cycle(.previous) == .changed)
    #expect(mac.focusedWindow == 4)

    mac.change {
      $0.windows[0] = window(1)
      $0.windows[3] = window(4, on: [], onScreen: false).with(app: 1, report: .missing)
      $0.focusedWindow = 1
    }
    #expect(try await atelier.slots() == [2, 3, 1])
  }

  @Test(arguments: [WindowFacts.Report.ordinary, .unanswered])
  func unknownMembershipWithoutEvidenceOfAbsenceKeepsTheSlot(report: WindowFacts.Report)
    async throws
  {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change { $0.windows[0] = window(1, on: [], onScreen: false).with(report: report) }
    #expect(try await atelier.slots() == [1, 2, 3])
  }

  @Test func missingMembershipOnAnInactiveDesktopProvesNothing() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change {
      $0.focusedWindow = nil
      $0.show(2)
      $0.windows[0] = window(1, on: [], onScreen: false).with(report: .missing)
    }
    _ = try await atelier.slots()
    mac.change {
      $0.show(1)
      $0.windows[0] = window(1)
    }
    #expect(try await atelier.slots() == [1, 2, 3])
  }

  @Test func aVisibleWindowMissingFromAccessibilityKeepsItsSlot() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    mac.change { $0.windows[0] = window(1, on: []).with(report: .missing) }
    #expect(try await atelier.slots() == [1, 2, 3])
  }

  @Test func anAppLeavingOutAWindowOnAHiddenDesktopProvesNothing() async throws {
    let mac = FakeMac(windows: [window(1), window(2, on: [2])])
    let atelier = Atelier(mac)
    mac.change { $0.show(2) }
    #expect(try await atelier.slots() == [2])
    mac.change {
      $0.show(1)
      $0.windows[1] = window(2, on: [2], onScreen: false).with(report: .missing)
    }
    _ = try await atelier.slots()
    mac.change { $0.show(2) }
    mac.change { $0.windows[1] = window(2, on: [2]) }
    #expect(try await atelier.slots() == [2])
  }

  @Test func aKnownWindowIsListedWhereItsAppCannotYetConfirmIt() async throws {
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    // Sent to a Desktop that is not showing, where its app leaves it out.
    mac.change { $0.windows[1] = window(2, on: [2], onScreen: false).with(report: .missing) }
    #expect(try await atelier.slots() == [1, 3])
    // It was listed there on arrival, so a window opened since comes after it.
    mac.change { $0.windows = [window(5, on: [2]), window(1), window(2, on: [2]), window(3)] }
    mac.change { $0.show(2) }
    #expect(try await atelier.slots() == [2, 5])
  }

  // MARK: - Across a relaunch

  private func folder() -> URL {
    URL.temporaryDirectory.appending(path: "atelier-tests-\(UUID().uuidString)")
  }

  @Test func orderSurvivesARelaunch() async throws {
    let folder = folder()
    // Saved by the time the move is done, not some time after.
    #expect(try await Atelier(mac, stateFolder: folder).windows.move(.toSlot(3)) == .changed)

    // Relaunched with another window focused, one closed, and one new.
    mac.change {
      $0.focusedWindow = 3
      $0.windows = [window(4), window(3), window(1)]
    }
    #expect(try await Atelier(mac, stateFolder: folder).slots() == [3, 1, 4])
  }

  @Test func restoringDropsAnInactiveTabWithoutSpaceMembership() async throws {
    let folder = folder()
    _ = try await Atelier(mac, stateFolder: folder).slots()
    mac.change {
      $0.windows[0] = window(1, on: [], onScreen: false).with(report: .missing)
      $0.windows.append(window(4).with(app: 1))
      $0.focusedWindow = 4
    }
    #expect(try await Atelier(mac, stateFolder: folder).slots() == [2, 3, 4])
  }

  @Test func aRecycledWindowNumberDoesNotInheritAPlace() async throws {
    let folder = folder()
    _ = try await Atelier(mac, stateFolder: folder).slots()
    // The same numbers, but the app has been launched again since.
    mac.change {
      $0.focusedWindow = nil
      $0.windows = [window(3), window(2), window(1).with(appLaunched: 2000)]
    }
    #expect(try await Atelier(mac, stateFolder: folder).slots() == [2, 3, 1])
  }

  @Test func aSavedListNeedsAWindowStillOnThatDesktop() async throws {
    let folder = folder()
    _ = try await Atelier(mac, stateFolder: folder).slots()
    // After a restart the same Space number can be another Desktop: every
    // saved window that is still open is somewhere else.
    mac.change {
      $0.focusedWindow = nil
      $0.windows = [window(3, on: [2]), window(2, on: [2]), window(9)]
    }
    let atelier = Atelier(mac, stateFolder: folder)
    #expect(try await atelier.slots() == [9])
    mac.change { $0.show(2) }
    #expect(try await atelier.slots() == [3, 2])
  }

  @Test func aWindowWithoutALaunchTimeIsListedButNotSaved() async throws {
    let folder = folder()
    let mac = FakeMac(
      focusedWindow: 1, windows: [window(1), window(2).with(appLaunched: .some(nil))])
    let first = Atelier(mac, stateFolder: folder)
    #expect(try await first.windows.move(.toSlot(2)) == .changed)
    #expect(try await first.slots() == [2, 1])
    mac.change { $0.focusedWindow = nil }
    #expect(try await Atelier(mac, stateFolder: folder).slots() == [1, 2])
  }

  @Test func anUnreadableFileStartsFresh() async throws {
    let folder = folder()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: folder.appending(path: "window-lists.json"))
    #expect(try await Atelier(mac, stateFolder: folder).slots() == [1, 2, 3])
  }
}
