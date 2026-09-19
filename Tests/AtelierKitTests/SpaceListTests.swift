import Foundation
import MacOS
import Testing

@testable import AtelierKit

/// `spaces move to`: the current Space to a position. Spaces 1 to 4 are in
/// order on one display; 2 is a full-screen Space and 4 a Split View Space.
@Suite struct SpaceMoveToTests {
  private func mac(current: UInt64) -> FakeMac {
    .oneDisplay(spaces: 1...4, notDesktops: [2, 4], current: current)
  }

  @Test(
    arguments: [
      (1, 3, [2, 3, 1, 4], "move 1 to 2"), (2, 1, [2, 1, 3, 4], "move 2 to 0"),
      (4, 2, [1, 4, 2, 3], "move 4 to 1"),
    ] as [(UInt64, Int, [UInt64], String)])
  func movesTheCurrentSpaceOfAnyKindAndKeepsItCurrent(
    current: UInt64, position: Int, order: [UInt64], request: String
  ) async throws {
    let mac = mac(current: current)
    #expect(try await Atelier(mac).spaces.move(to: position) == .changed)
    #expect(mac.spaceOrder == order)
    #expect(mac.currentSpace == current)
    #expect(mac.requests == [request])
  }

  @Test func aPositionPastTheEndIsTheEnd() async throws {
    let mac = mac(current: 2)
    let atelier = Atelier(mac)
    #expect(try await atelier.spaces.move(to: 9) == .changed)
    #expect(mac.spaceOrder == [1, 3, 4, 2])
    #expect(mac.currentSpace == 2)
    // At the end already, so past the end is where it is.
    #expect(try await atelier.spaces.move(to: .max) == .unchanged)
    #expect(mac.requests == ["move 2 to 3"])
  }

  @Test func itsOwnPositionAndNoPositionAreNothingToDo() async throws {
    let mac = mac(current: 3)
    let atelier = Atelier(mac)
    #expect(try await atelier.spaces.move(to: 3) == .unchanged)
    #expect(try await atelier.spaces.move(to: 0) == .unchanged)
    #expect(try await atelier.spaces.move(to: .min) == .unchanged)
    #expect(mac.requests.isEmpty)
  }

  @Test func nothingIsMovedWhenTheSpacesChangedSinceTheCensus() async throws {
    let mac = mac(current: 1)
    mac.change { state in
      state.afterSnapshot = { $0.replaceSpaces { $0.reversed() } }
    }
    await #expect(
      throws: AtelierError.targetChanged("The Spaces changed just before, so nothing was moved.")
    ) { try await Atelier(mac).spaces.move(to: 2) }
    #expect(mac.requests.isEmpty)
    #expect(mac.spaceOrder == [4, 3, 2, 1])
  }

  @Test func needsOneDisplay() async {
    let mac = FakeMac()
    await #expect(
      throws: AtelierError.unsupported("Atelier can reorder Spaces only with one display for now.")
    ) { try await Atelier(mac).spaces.move(to: 2) }
    #expect(mac.requests.isEmpty)
  }

  @Test func aMoveThatDoesNotShowIsUncertainAndARefusedOneDidNotHappen() async throws {
    let mac = mac(current: 1)
    mac.change { $0.ignoresSpaceChanges = true }
    await #expect(
      throws: AtelierError.uncertain("macOS did not confirm the move. Check Mission Control.")
    ) { try await Atelier(mac).spaces.move(to: 2) }
    mac.change {
      $0.ignoresSpaceChanges = false
      $0.moveResult = .refused("Moving a Space is unavailable on this macOS")
    }
    await #expect(throws: AtelierError.unsupported("Moving a Space is unavailable on this macOS")) {
      try await Atelier(mac).spaces.move(to: 2)
    }
    #expect(mac.spaceOrder == [1, 2, 3, 4])
  }

  @Test func aMoveThatLeavesAnotherSpaceCurrentIsNotConfirmed() async throws {
    let mac = mac(current: 1)
    // macOS moves the Space and, against all it has shown, shows another.
    mac.change { $0.afterMove = { $0.show(3) } }
    await #expect(
      throws: AtelierError.uncertain("macOS did not confirm the move. Check Mission Control.")
    ) { try await Atelier(mac).spaces.move(to: 2) }
  }

  @Test func theWordsOfTheCommand() {
    #expect(Command(words: "spaces move to 3") == .spacesMoveTo(3))
    #expect(Command.spacesMoveTo(3).words == "spaces move to 3")
    #expect(Command.spacesMoveTo(3).label == "Move Space to 3")
    #expect(Command(words: "spaces move to") == nil)
    #expect(Command(words: "spaces move to three") == nil)
    // The other forms are as they were.
    #expect(Command(words: "spaces move by -1") == .spacesMoveBy(-1))
    #expect(Command(words: "spaces move 1 3") == .spacesMove(from: 1, to: 3))
  }
}

/// The default keys count Spaces of every kind. Desktop, full screen,
/// Desktop are Spaces 1, 2, and 3 of one display.
@Suite struct SpaceNumberKeyTests {
  private func start(_ mac: FakeMac) async -> Atelier {
    let atelier = Atelier(mac)
    await atelier.config.ready()
    return atelier
  }

  @Test func aNumberSelectsThatPositionWhateverIsThere() async throws {
    let mac = FakeMac.oneDisplay(notDesktops: [2], current: 1)
    let atelier = await start(mac)
    mac.press(chord("option+2"))
    #expect(await eventually { mac.currentSpace == 2 })
    #expect(
      await eventually {
        (try? await atelier.spaces.list().spaces.map(\.isCurrent)) == [false, true, false]
      })
    mac.press(chord("option+3"))
    #expect(await eventually { mac.requests == ["switch to 2", "switch to 3"] })
  }

  @Test func zeroIsTheTenthPositionAndLaterSpacesHaveNoKey() async throws {
    let mac = FakeMac.oneDisplay(spaces: 1...12, notDesktops: [10], current: 1)
    let atelier = await start(mac)
    #expect(try await atelier.spaces.list().spaces.count == 12)
    mac.press(chord("option+0"))
    #expect(await eventually { mac.currentSpace == 10 })
  }

  @Test func shiftMovesTheCurrentSpaceToTheNumberOrTheEnd() async throws {
    let mac = FakeMac.oneDisplay(spaces: 1...4, notDesktops: [2], current: 2)
    let atelier = await start(mac)
    mac.press(chord("option+shift+9"))
    #expect(await eventually { mac.spaceOrder == [1, 3, 4, 2] })
    #expect(mac.currentSpace == 2)
    #expect(
      await eventually {
        (try? await atelier.spaces.list().spaces.map(\.isCurrent)) == [false, false, false, true]
      })
    mac.press(chord("option+shift+1"))
    #expect(await eventually { mac.spaceOrder == [2, 1, 3, 4] })
    #expect(mac.currentSpace == 2)
  }

  @Test func aFailedMoveIsANoticeAndNothingMoves() async throws {
    let mac = FakeMac()
    let atelier = await start(mac)
    var notices = atelier.notices.changes().makeAsyncIterator()
    mac.press(chord("option+shift+2"))
    #expect(
      await notices.next()
        == Notice(text: "Atelier can reorder Spaces only with one display for now."))
    #expect(mac.requests.isEmpty)
  }
}

/// Holding the Space list's modifiers, and what ends a showing of the list.
@Suite struct SpaceListHoldTests {
  private let folder = FileManager.default.temporaryDirectory.appending(
    path: "atelier-space-list-\(UUID().uuidString.prefix(8))")
  private var file: URL { folder.appending(path: "config.toml") }

  private func start(_ mac: FakeMac, config: String? = nil) async throws -> Atelier {
    if let config { try write(config) }
    let atelier = Atelier(mac, configFile: config == nil ? nil : file)
    await atelier.config.ready()
    return atelier
  }

  private func write(_ config: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try config.write(to: file, atomically: true, encoding: .utf8)
  }

  private let held = SpaceListHold.held(delay: .milliseconds(200))

  @Test func optionAloneIsHeldShiftToleratedAndAnythingElseIsAnotherChord() async throws {
    let mac = FakeMac()
    let atelier = try await start(mac)
    var holds = atelier.holds.changes().makeAsyncIterator()
    mac.hold([.shift])
    mac.hold([.option])
    #expect(await holds.next() == ListHolds(windows: false, spaces: held))
    // Shift joins for the reorder shortcuts, and leaves, without a word.
    mac.hold([.option, .shift])
    mac.hold([.option])
    mac.hold([.option, .control])
    #expect(await holds.next() == ListHolds(windows: false, spaces: .suppressed))
    mac.hold([.option])
    #expect(await holds.next() == ListHolds(windows: false, spaces: held))
    mac.hold([])
    #expect(await holds.next() == ListHolds(windows: false, spaces: .released))
  }

  @Test func withTheWindowListsModifiersTheSpaceListsHoldGoesOnUnwanted() async throws {
    let mac = FakeMac()
    let atelier = try await start(mac)
    var holds = atelier.holds.changes().makeAsyncIterator()
    mac.hold([.option])
    mac.hold([.command, .option])
    mac.hold([.command, .option, .shift])
    mac.hold([.command, .option, .control])
    mac.hold([.option])
    mac.hold([.command])
    #expect(await holds.next() == ListHolds(windows: false, spaces: held))
    // Option stayed down throughout, so for the Space list it is all one hold.
    #expect(await holds.next() == ListHolds(windows: true, spaces: .suppressed))
    #expect(await holds.next() == ListHolds(windows: false, spaces: .suppressed))
    #expect(await holds.next() == ListHolds(windows: false, spaces: held))
    #expect(await holds.next() == ListHolds(windows: false, spaces: .released))
  }

  @Test func aReleaseBetweenTwoHoldsIsNeverMissed() async throws {
    let mac = FakeMac()
    let atelier = try await start(mac)
    var holds = atelier.holds.changes().makeAsyncIterator()
    // All at once, before anyone has looked.
    mac.hold([.option])
    mac.hold([])
    mac.hold([.option])
    #expect(await holds.next()?.spaces == held)
    #expect(await holds.next()?.spaces == .released)
    #expect(await holds.next()?.spaces == held)
  }

  @Test func whereTheTwoListsShareModifiersTheWindowListComesFirst() async throws {
    let mac = FakeMac()
    let atelier = try await start(
      mac, config: "[space-list]\nmodifiers = \"cmd+option\"\n")
    var holds = atelier.holds.changes().makeAsyncIterator()
    mac.hold([.command, .option])
    mac.hold([])
    #expect(await holds.next() == ListHolds(windows: true, spaces: .suppressed))
    #expect(await holds.next() == ListHolds(windows: false, spaces: .released))
  }

  @Test func theModifiersAndDelayAreTheConfiguredOnesAfterAReloadToo() async throws {
    let mac = FakeMac()
    let atelier = try await start(
      mac,
      config: """
        [window-list]
        modifiers = "ctrl+cmd"

        [space-list]
        modifiers = "ctrl+option"
        delay = 0
        """)
    var holds = atelier.holds.changes().makeAsyncIterator()
    mac.hold([.option])
    mac.hold([.control, .option])
    #expect(await holds.next()?.spaces == .held(delay: .zero))
    mac.hold([.control, .command])
    #expect(await holds.next() == ListHolds(windows: true, spaces: .released))
    mac.hold([])
    #expect(await holds.next() == ListHolds(windows: false, spaces: .released))
    try write("[space-list]\ndelay = 1.5\n")
    #expect(try await atelier.config.reload().outcome == .changed)
    // Option alone again, as the file no longer says otherwise.
    mac.hold([.control, .option])
    #expect(await holds.next()?.spaces == .suppressed)
    mac.hold([.option])
    #expect(await holds.next()?.spaces == .held(delay: .milliseconds(1500)))
  }

  @Test func turnedOffNothingIsHeldAndTheNumberKeysStillWork() async throws {
    let mac = FakeMac.oneDisplay(notDesktops: [2], current: 1)
    let atelier = try await start(mac, config: "[space-list]\nenabled = false\n")
    var holds = atelier.holds.changes().makeAsyncIterator()
    mac.hold([.option])
    mac.press(chord("option+2"))
    #expect(await eventually { mac.currentSpace == 2 })
    mac.hold([])
    // Turned on again, the first thing heard is the next hold.
    try write("")
    #expect(try await atelier.config.reload().outcome == .changed)
    mac.hold([.option])
    #expect(await holds.next() == ListHolds(windows: false, spaces: held))
  }

  @Test func choosingASpaceIsAnnouncedBeforeAnythingComesOfIt() async throws {
    let mac = FakeMac.oneDisplay(current: 1)
    // The switch never happens, so the command is still running when the news comes.
    mac.change { $0.ignoresSwitches = true }
    var patience = Patience.short
    patience.transition = .milliseconds(400)
    let atelier = Atelier(mac: mac, patience: patience)
    await atelier.config.ready()
    var selections = await atelier.spaces.selections().makeAsyncIterator()
    mac.press(chord("option+2"))
    await selections.next()
    #expect(await eventually { mac.requests == ["switch to 2"] })
    // A second choice is refused as busy, and is news all the same.
    await #expect(throws: AtelierError.busy) { try await atelier.spaces.select(position: 3) }
    await selections.next()
  }

  /// Each from Desktop 1 of three. The current position is nothing to do,
  /// and a choice all the same.
  @Test(arguments: ["spaces select 1", "spaces next", "spaces previous", "desktops select 3"])
  func everyWayOfChoosingASpaceIsAnnounced(words: String) async throws {
    let atelier = try await start(FakeMac.oneDisplay(current: 1))
    var selections = await atelier.spaces.selections().makeAsyncIterator()
    _ = try await atelier.perform(try #require(Command(words: words)))
    await selections.next()
  }

  @Test func theListFollowsTheKeyboardToAnotherDisplayWithEverySpaceWhereItWas() async throws {
    let mac = FakeMac(focusedWindow: 1, windows: [window(1), window(2, on: [3])])
    let atelier = try await start(mac)
    #expect(try await atelier.spaces.list().display == "first")
    var changes = await atelier.spaces.changes().makeAsyncIterator()
    mac.change { $0.focusedWindow = 2 }
    mac.hint()
    await changes.next()
    let list = try await atelier.spaces.list()
    #expect(list.display == "second")
    #expect(list.spaces.map(\.id) == [3, 4, 5])
    #expect(list.spaces.map(\.isCurrent) == [true, false, false])
  }
}
