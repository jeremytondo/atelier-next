import AtelierKit
import MacOS
import Testing

/// Making and deleting Desktops. Spaces 1 to 4 are in order on one display
/// and 3 is a full-screen Space, so the Desktops are 1, 2, and 4.
@Suite struct DesktopTests {
  private func mac(current: UInt64, windows: [WindowFacts] = []) -> FakeMac {
    .oneDisplay(spaces: 1...4, notDesktops: [3], current: current, windows: windows)
  }

  // MARK: - New

  @Test func newAddsOneDesktopAtTheEndAndEntersIt() async throws {
    let mac = mac(current: 1)
    #expect(try await Session(mac).desktops.new() == .done)
    #expect(mac.spaceOrder == [1, 2, 3, 4, 100])
    #expect(mac.currentSpace == 100)
    #expect(mac.requests == ["create", "switch to 100"])
  }

  @Test func newIsRefusedFromAFullScreenSpace() async throws {
    let mac = mac(current: 3)
    await #expect(throws: AtelierError.self) { try await Session(mac).desktops.new() }
    #expect(mac.requests.isEmpty)
  }

  @Test func newIsRefusedWhileMissionControlIsOpen() async throws {
    let mac = mac(current: 1)
    mac.change { $0.isMissionControlOpen = true }
    await #expect(throws: AtelierError.failed("Close Mission Control to create a Desktop.")) {
      try await Session(mac).desktops.new()
    }
    #expect(mac.requests.isEmpty)
  }

  @Test func newIsRefusedWhenMacOSCannot() async throws {
    let mac = mac(current: 1)
    mac.change { $0.creation = .refused("Changing Desktops needs macOS 27") }
    await #expect(throws: AtelierError.unsupported("Changing Desktops needs macOS 27")) {
      try await Session(mac).desktops.new()
    }
    #expect(mac.requests == ["create"])
  }

  @Test func newIsRefusedWhenDockWillNotSayWhetherMissionControlIsOpen() async throws {
    let mac = mac(current: 1)
    mac.change { $0.isMissionControlOpen = nil }
    await #expect(throws: AtelierError.self) { try await Session(mac).desktops.new() }
    #expect(mac.requests.isEmpty)
  }

  @Test func aDesktopThatNeverAppearsIsReportedWithItsNumber() async throws {
    let mac = mac(current: 1)
    mac.change { $0.createsUnseenDesktop = true }
    await #expect(
      throws: AtelierError.desktopCreated(
        100, then: "macOS made Desktop 100 but it did not appear as expected.")
    ) { try await Session(mac).desktops.new() }
    #expect(mac.requests == ["create"])
  }

  @Test func aDesktopThatCannotBeEnteredIsReportedWithItsNumber() async throws {
    let mac = mac(current: 1)
    mac.change { $0.ignoresSwitches = true }
    await #expect(
      throws: AtelierError.desktopCreated(
        100, then: "The new Desktop was made, but Atelier could not switch to it.")
    ) { try await Session(mac).desktops.new() }
    // Asked once; never tried again.
    #expect(mac.requests.filter { $0 == "create" }.count == 1)
  }

  @Test func aCreationThatFailedPartWayIsUncertain() async throws {
    let mac = mac(current: 1)
    mac.change { $0.creation = .uncertain("Desktop creation returned no Desktop") }
    await #expect(
      throws: AtelierError.uncertain("Desktop creation returned no Desktop")
    ) { try await Session(mac).desktops.new() }
  }

  // MARK: - Delete

  @Test func deleteEntersTheNextDesktopThenDeletesTheOneItLeft() async throws {
    let mac = mac(current: 2)
    #expect(try await Session(mac).desktops.delete() == .done)
    #expect(mac.spaceOrder == [1, 3, 4])
    #expect(mac.currentSpace == 4)
    #expect(mac.requests == ["switch to 4", "destroy 2"])
  }

  @Test func deletingTheLastDesktopEntersThePreviousOne() async throws {
    let mac = mac(current: 4)
    #expect(try await Session(mac).desktops.delete() == .done)
    #expect(mac.spaceOrder == [1, 2, 3])
    #expect(mac.currentSpace == 2)
  }

  @Test func theOnlyDesktopCannotBeDeleted() async throws {
    let mac = FakeMac.oneDisplay(spaces: 1...2, notDesktops: [2])
    await #expect(throws: AtelierError.failed("The only Desktop cannot be deleted.")) {
      try await Session(mac).desktops.delete()
    }
    #expect(mac.requests.isEmpty)
  }

  @Test func aFullScreenSpaceIsNotDeleted() async throws {
    let mac = mac(current: 3)
    await #expect(throws: AtelierError.self) { try await Session(mac).desktops.delete() }
    #expect(mac.requests.isEmpty)
  }

  @Test func windowsOfADeletedDesktopJoinTheirNewListAsArrivals() async throws {
    let mac = mac(
      current: 2, windows: [window(1, on: [2]), window(2, on: [2]), window(3, on: [4])])
    let session = Session(mac)
    #expect(try await session.slots() == [1, 2])
    #expect(try await session.desktops.delete() == .done)
    #expect(try await session.slots() == [3, 1, 2])
  }

  @Test func nothingIsDeletedWhenTheDesktopsChangeAfterLeaving() async throws {
    let mac = mac(current: 2)
    // Someone reorders Desktops just as Atelier arrives on the next one.
    mac.change { state in
      state.afterSwitch = { $0.replaceSpaces { [$0[1], $0[0], $0[2], $0[3]] } }
    }
    await #expect(
      throws: AtelierError.targetChanged(
        "The Desktops changed just before, so nothing was deleted.")
    ) { try await Session(mac).desktops.delete() }
    #expect(mac.requests == ["switch to 4"])
  }

  @Test func nothingIsDeletedWhenTheDesktopCannotBeLeft() async throws {
    let mac = mac(current: 2)
    mac.change { $0.ignoresSwitches = true }
    await #expect(
      throws: AtelierError.failed("macOS did not switch to the Space Atelier asked for.")
    ) {
      try await Session(mac).desktops.delete()
    }
    #expect(mac.requests == ["switch to 4"])
    #expect(mac.spaceOrder == [1, 2, 3, 4])
  }

  @Test func aDeletionThatDoesNotShowIsUncertain() async throws {
    let mac = mac(current: 2)
    mac.change { $0.ignoresSpaceChanges = true }
    await #expect(
      throws: AtelierError.uncertain("macOS did not confirm the deletion. Check Mission Control.")
    ) { try await Session(mac).desktops.delete() }
    #expect(mac.requests.filter { $0.hasPrefix("destroy") } == ["destroy 2"])
  }

  // MARK: - Every change

  @Test func desktopsAreManagedOnOneDisplayOnly() async throws {
    let mac = FakeMac()
    let session = Session(mac)
    await #expect(throws: AtelierError.self) { try await session.desktops.new() }
    await #expect(throws: AtelierError.self) { try await session.desktops.delete() }
    #expect(mac.requests.isEmpty)
  }

  @Test func desktopsThatChangedSinceTheCensusAreNotActedOn() async throws {
    for command in ["new", "delete"] {
      let mac = mac(current: 2)
      let session = Session(mac)
      mac.change { state in
        state.afterSnapshot = { $0.replaceSpaces { [$0[1], $0[0], $0[2], $0[3]] } }
      }
      await #expect(throws: AtelierError.self) {
        switch command {
        case "new": try await session.desktops.new()
        default: try await session.desktops.delete()
        }
      }
      #expect(mac.requests.isEmpty, "\(command)")
    }
  }
}
