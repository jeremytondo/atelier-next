import Foundation
import SpaceControlCore
import Testing

@testable import AtelierEngine

private func desktop(_ id: UInt64, fullscreen: Bool = false) -> ManagedSpaceSnapshot {
  ManagedSpaceSnapshot(id: id, isFullscreen: fullscreen, rawType: fullscreen ? 4 : 0)
}

private func display(
  _ spaces: [ManagedSpaceSnapshot], current: UInt64, id: String = "A"
) -> DisplaySpaceSnapshot {
  DisplaySpaceSnapshot(identifier: id, currentSpaceID: current, spaces: spaces)
}

/// One display whose native state the sequence mutates through the seams.
private final class FakeMac {
  var time: TimeInterval = 0
  var topology: [DisplaySpaceSnapshot]
  var missionControl = false
  var dock: Int? = 3
  var dispatch: CreationDispatch = .created(5)
  var censusReflectsCreation = true
  var createdAsFullscreen = false
  var dockRegisters = true
  var disturbDuringDockWait = false
  var enterAccepted = true
  var enterArrives = true
  var creates = 0
  var entries: [Int] = []

  init(_ topology: [DisplaySpaceSnapshot]) { self.topology = topology }

  var seams: DesktopCreationSeams {
    DesktopCreationSeams(
      topology: { self.topology },
      missionControlVisible: { self.missionControl },
      dockCount: {
        if self.disturbDuringDockWait, self.creates > 0 {
          self.topology[0] = display([desktop(1)], current: 1)
        }
        return self.dock
      },
      create: {
        self.creates += 1
        if case .created(let id) = self.dispatch, self.censusReflectsCreation {
          let display = self.topology[0]
          self.topology[0] = DisplaySpaceSnapshot(
            identifier: display.identifier, currentSpaceID: display.currentSpaceID,
            spaces: display.spaces + [desktop(id, fullscreen: self.createdAsFullscreen)])
          if self.dockRegisters, let dock = self.dock { self.dock = dock + 1 }
        }
        return self.dispatch
      },
      enterDesktop: { number in
        self.entries.append(number)
        let display = self.topology[0]
        if self.enterArrives, let target = SpaceTopology.desktop(number: number, on: "A", displays: self.topology) {
          self.topology[0] = DisplaySpaceSnapshot(
            identifier: display.identifier, currentSpaceID: target.id, spaces: display.spaces)
        }
        return self.enterAccepted
      },
      now: { self.time },
      pause: { self.time += 0.02 })
  }
}

private let start = [display([desktop(1), desktop(2), desktop(90, fullscreen: true)], current: 2)]

private func failure(_ mac: FakeMac) -> DesktopCreationError? {
  do {
    _ = try DesktopCreation.createAndEnter(on: "A", seams: mac.seams)
    return nil
  } catch let error as DesktopCreationError {
    return error
  } catch {
    Issue.record("unexpected error \(error)")
    return nil
  }
}

@Test func createsAtTheEndWaitsForDockAndEntersByNumber() throws {
  let mac = FakeMac(start)
  #expect(try DesktopCreation.createAndEnter(on: "A", seams: mac.seams) == 5)
  #expect(mac.creates == 1)
  #expect(mac.entries == [3])
  #expect(mac.topology[0].spaces.map(\.id) == [1, 2, 90, 5])
  #expect(mac.topology[0].currentSpaceID == 5)
}

@Test func refusesUnsupportedStateBeforeDispatch() {
  let twoDisplays = FakeMac(start + [display([desktop(10)], current: 10, id: "B")])
  #expect(failure(twoDisplays)?.message.contains("one display") == true)
  let overview = FakeMac(start)
  overview.missionControl = true
  #expect(failure(overview)?.message.contains("Mission Control") == true)
  let fullscreen = FakeMac([display([desktop(1), desktop(90, fullscreen: true)], current: 90)])
  #expect(failure(fullscreen)?.message.contains("full-screen") == true)
  let noDock = FakeMac(start)
  noDock.dock = nil
  #expect(failure(noDock)?.message.contains("Dock") == true)
  for mac in [twoDisplays, overview, fullscreen, noDock] {
    #expect(mac.creates == 0 && mac.entries.isEmpty)
  }
}

@Test func dispatchFailuresCarryNoCreatedID() {
  let refused = FakeMac(start)
  refused.dispatch = .refused("The native Desktop creation operation is unavailable on this macOS")
  let refusal = failure(refused)
  #expect(refusal?.createdID == nil)
  #expect(refusal?.errorDescription?.contains("unavailable") == true)
  let uncertain = FakeMac(start)
  uncertain.dispatch = .uncertain("Desktop creation returned no ID; check Mission Control before trying again")
  let outcome = failure(uncertain)
  #expect(outcome?.createdID == nil)
  #expect(outcome?.errorDescription?.contains("check Mission Control") == true)
  #expect(refused.entries.isEmpty && uncertain.entries.isEmpty)
}

@Test func rejectedConfirmationReportsTheCreatedIDWithoutEntering() {
  let mac = FakeMac(start)
  mac.createdAsFullscreen = true
  let error = failure(mac)
  #expect(error?.createdID == 5)
  #expect(error?.errorDescription?.contains("Desktop 5 was created") == true)
  #expect(error?.message.contains("not an ordinary Desktop") == true)
  #expect(mac.entries.isEmpty)
}

@Test func unconfirmedCreationTimesOutAndReportsTheCreatedID() {
  let mac = FakeMac(start)
  mac.censusReflectsCreation = false
  let error = failure(mac)
  #expect(error?.createdID == 5)
  #expect(error?.message.contains("did not confirm") == true)
  #expect(mac.time >= DesktopCreation.confirmationTimeout)
  #expect(mac.entries.isEmpty)
}

@Test func unregisteredOrDisturbedDockWaitDoesNotEnter() {
  let lagging = FakeMac(start)
  lagging.dockRegisters = false
  let error = failure(lagging)
  #expect(error?.createdID == 5)
  #expect(error?.message.contains("Dock did not register") == true)
  #expect(lagging.entries.isEmpty)
  let disturbed = FakeMac(start)
  disturbed.disturbDuringDockWait = true
  #expect(failure(disturbed)?.message.contains("changed while Dock") == true)
  #expect(disturbed.entries.isEmpty)
}

@Test func creationBeyondTheNumberedShortcutLimitIsReportedNotEntered() {
  let sixteen = (1...16).map { desktop(UInt64($0)) }
  let mac = FakeMac([display(sixteen, current: 16)])
  mac.dispatch = .created(50)
  mac.dock = 16
  let error = failure(mac)
  #expect(error?.createdID == 50)
  #expect(error?.message.contains("beyond Desktop 16") == true)
  #expect(mac.entries.isEmpty)
  #expect(mac.topology[0].spaces.count == 17)
}

@Test func entryFailuresReportTheCreatedIDWithoutReplay() {
  let unavailable = FakeMac(start)
  unavailable.enterAccepted = false
  #expect(failure(unavailable)?.message.contains("shortcut unavailable") == true)
  let unverified = FakeMac(start)
  unverified.enterArrives = false
  let error = failure(unverified)
  #expect(error?.createdID == 5)
  #expect(error?.message.contains("not verified") == true)
  #expect(unverified.time >= DesktopCreation.entryTimeout)
  for mac in [unavailable, unverified] {
    #expect(mac.creates == 1 && mac.entries == [3])
  }
}
