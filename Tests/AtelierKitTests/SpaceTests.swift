import AtelierKit
import MacOS
import Testing

/// Moving between Spaces of every kind. Spaces 1 to 5 are in order on one
/// display; 2 is a full-screen Space and 5 a Split View Space, so the
/// Desktops are 1, 3, and 4.
@Suite struct SpaceTests {
  private func mac(current: UInt64) -> FakeMac {
    .oneDisplay(spaces: 1...5, notDesktops: [2, 5], current: current)
  }

  @Test func listsEveryKindOfSpaceInOrder() async throws {
    let list = try await Session(mac(current: 3)).spaces.list()
    #expect(list.display == "only")
    #expect(list.spaces.map(\.id) == [1, 2, 3, 4, 5])
    #expect(list.spaces.map(\.desktopNumber) == [1, nil, 2, 3, nil])
    #expect(list.spaces.map(\.isCurrent) == [false, false, true, false, false])
  }

  @Test func nextAndPreviousStepThroughEveryKind() async throws {
    let mac = mac(current: 1)
    let session = Session(mac)
    for expected in [2, 3, 4, 5] as [UInt64] {
      #expect(try await session.spaces.next() == .done)
      #expect(mac.currentSpace == expected)
    }
    for expected in [4, 3, 2, 1] as [UInt64] {
      #expect(try await session.spaces.previous() == .done)
      #expect(mac.currentSpace == expected)
    }
  }

  @Test func nextWrapsFromTheLastSpaceToTheFirst() async throws {
    let mac = mac(current: 5)
    #expect(try await Session(mac).spaces.next() == .done)
    #expect(mac.currentSpace == 1)
  }

  @Test func previousWrapsToALastSpaceThatIsNotADesktop() async throws {
    let mac = mac(current: 1)
    #expect(try await Session(mac).spaces.previous() == .done)
    #expect(mac.currentSpace == 5)
  }

  @Test func withOneSpaceNextIsNothingToDo() async throws {
    let mac = FakeMac.oneDisplay(spaces: 1...1)
    #expect(try await Session(mac).spaces.next() == .noop)
    #expect(mac.requests.isEmpty)
  }

  @Test func selectsAnyKindOfSpaceByPosition() async throws {
    let mac = mac(current: 4)
    let session = Session(mac)
    #expect(try await session.spaces.select(position: 2) == .done)
    #expect(mac.currentSpace == 2)
    #expect(try await session.spaces.select(position: 5) == .done)
    #expect(mac.currentSpace == 5)
  }

  @Test func aPositionIsNeverTakenForADesktopNumber() async throws {
    let mac = mac(current: 1)
    let session = Session(mac)
    #expect(try await session.spaces.select(position: 3) == .done)
    #expect(mac.currentSpace == 3)
    #expect(try await session.desktops.select(number: 3) == .done)
    #expect(mac.currentSpace == 4)
  }

  @Test func outOfRangeAndCurrentSelectionsAreNothingToDo() async throws {
    let mac = mac(current: 3)
    let session = Session(mac)
    #expect(try await session.spaces.select(position: 6) == .noop)
    #expect(try await session.spaces.select(position: 0) == .noop)
    #expect(try await session.spaces.select(position: 3) == .noop)
    #expect(try await session.desktops.select(number: 4) == .noop)
    #expect(try await session.desktops.select(number: 0) == .noop)
    #expect(try await session.desktops.select(number: 2) == .noop)
    #expect(mac.requests.isEmpty)
  }

  @Test func aSwitchThatDoesNotHappenIsAFailure() async throws {
    let mac = mac(current: 1)
    mac.change { $0.ignoresSwitches = true }
    await #expect(
      throws: AtelierError.failed("macOS did not switch to the Space Atelier asked for.")
    ) {
      try await Session(mac).spaces.next()
    }
  }

  @Test func spacesThatChangedSinceTheCensusAreNotActedOn() async throws {
    let mac = mac(current: 1)
    mac.change { state in
      state.afterSnapshot = { $0.replaceSpaces { $0.reversed() } }
    }
    await #expect(
      throws: AtelierError.targetChanged("The Spaces changed before Atelier could switch.")
    ) {
      try await Session(mac).spaces.next()
    }
    #expect(mac.requests.isEmpty)
  }

  @Test func aSpaceMacOSCannotReachIsUnsupported() async throws {
    let mac = mac(current: 1)
    mac.change { $0.switchResult = .refused("No shortcut reaches that Space.") }
    await #expect(throws: AtelierError.unsupported("No shortcut reaches that Space.")) {
      try await Session(mac).spaces.next()
    }
  }

  @Test func extremeNumbersAreNothingToDo() async throws {
    let session = Session(mac(current: 1))
    for number in [Int.min, -1, Int.max] {
      #expect(try await session.spaces.select(position: number) == .noop)
      #expect(try await session.desktops.select(number: number) == .noop)
      #expect(try await session.windows.select(number) == .noop)
    }
  }

  // MARK: - Move

  @Test func movesASpaceToAPositionLikeMissionControl() async throws {
    let mac = mac(current: 3)
    #expect(try await Session(mac).spaces.move(from: 1, to: 3) == .done)
    #expect(mac.spaceOrder == [2, 3, 1, 4, 5])
    #expect(mac.currentSpace == 3)
    #expect(mac.requests == ["move 1 to 2"])
  }

  @Test func movesAFullScreenSpaceAndTheCurrentSpace() async throws {
    let mac = mac(current: 4)
    let session = Session(mac)
    #expect(try await session.spaces.move(from: 2, to: 5) == .done)
    #expect(mac.spaceOrder == [1, 3, 4, 5, 2])
    #expect(try await session.spaces.move(from: 3, to: 1) == .done)
    #expect(mac.spaceOrder == [4, 1, 3, 5, 2])
    #expect(mac.currentSpace == 4)
  }

  @Test func movesWhileAFullScreenSpaceIsCurrent() async throws {
    let mac = mac(current: 2)
    #expect(try await Session(mac).spaces.move(from: 4, to: 1) == .done)
    #expect(mac.spaceOrder == [4, 1, 2, 3, 5])
    #expect(mac.currentSpace == 2)
  }

  @Test func movesOutOfRangeOrInPlaceAreNothingToDo() async throws {
    let mac = mac(current: 1)
    let session = Session(mac)
    #expect(try await session.spaces.move(from: 6, to: 1) == .noop)
    #expect(try await session.spaces.move(from: 1, to: 6) == .noop)
    #expect(try await session.spaces.move(from: 0, to: 1) == .noop)
    #expect(try await session.spaces.move(from: 3, to: 3) == .noop)
    #expect(try await session.spaces.move(from: Int.min, to: Int.max) == .noop)
    #expect(mac.requests.isEmpty)
  }

  @Test func aMoveThatDoesNotShowIsUncertain() async throws {
    let mac = mac(current: 1)
    mac.change { $0.ignoresSpaceChanges = true }
    await #expect(
      throws: AtelierError.uncertain("macOS did not confirm the move. Check Mission Control.")
    ) { try await Session(mac).spaces.move(from: 1, to: 2) }
    #expect(mac.requests == ["move 1 to 1"])
  }

  @Test func aMoveMacOSRefusesDidNotHappen() async throws {
    let mac = mac(current: 1)
    mac.change { $0.moveResult = .refused("Moving a Space is unavailable on this macOS") }
    await #expect(throws: AtelierError.unsupported("Moving a Space is unavailable on this macOS")) {
      try await Session(mac).spaces.move(from: 1, to: 2)
    }
    #expect(mac.spaceOrder == [1, 2, 3, 4, 5])
  }

  @Test func nothingIsMovedWhenTheSpacesChangedSinceTheCensus() async throws {
    let mac = mac(current: 1)
    mac.change { state in
      state.afterSnapshot = { $0.replaceSpaces { $0.reversed() } }
    }
    await #expect(throws: AtelierError.self) { try await Session(mac).spaces.move(from: 1, to: 2) }
    #expect(mac.requests.isEmpty)
  }

  @Test func spacesAreMovedOnOneDisplayOnly() async throws {
    let mac = FakeMac()
    await #expect(throws: AtelierError.self) { try await Session(mac).spaces.move(from: 1, to: 2) }
    #expect(mac.requests.isEmpty)
  }
}
