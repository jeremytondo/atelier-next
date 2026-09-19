import Foundation
import Testing

@testable import MacOS

@Suite struct FullScreenWindowTests {
  private func tile(window: Int, app: Int = 42, space: Int = 7) -> [String: Any] {
    ["ManagedSpaceID": space, "TileWindowID": window, "fs_wid": window, "pid": app]
  }

  private func target(window: Int = 100, app: Int = 42, tiles: [[String: Any]]? = nil)
    -> [String: Any]
  {
    [
      "ManagedSpaceID": 7, "type": 4, "fs_wid": window, "pid": app,
      "TileLayoutManager": ["TileSpaces": tiles ?? [tile(window: window, app: app)]],
    ]
  }

  private func read(_ target: [String: Any]) -> FullScreenWindow? {
    FullScreenWindow.read(
      space: 7, on: "Main",
      from: [["Display Identifier": "Main", "Spaces": [target]]])
  }

  @Test func identifiesTheWindowBySpaceIDAndDisplay() {
    let raw: [[String: Any]] = [
      ["Display Identifier": "Other", "Spaces": [target(window: 300)]],
      [
        "Display Identifier": "Main",
        "Spaces": [["ManagedSpaceID": 1, "type": 0], target()],
      ],
    ]
    #expect(
      FullScreenWindow.read(space: 7, on: "Main", from: raw)
        == FullScreenWindow(id: 100, app: 42))
    #expect(FullScreenWindow.read(space: 1, on: "Main", from: raw) == nil)
    #expect(FullScreenWindow.read(space: 7, on: "Missing", from: raw) == nil)
  }

  @Test func splitViewUsesTheRepresentativeWindowRatherThanTheFirstTile() {
    #expect(
      read(target(window: 200, app: 43, tiles: [tile(window: 100), tile(window: 200, app: 43)]))
        == FullScreenWindow(id: 200, app: 43))
  }

  @Test func rejectsAWindowThatIsNotInItsSpace() {
    #expect(read(target(tiles: [tile(window: 101)])) == nil)
    #expect(read(target(tiles: [tile(window: 100, app: 43)])) == nil)
    #expect(read(target(tiles: [tile(window: 100, space: 8)])) == nil)
    var wrongWindow = tile(window: 100)
    wrongWindow["TileWindowID"] = 101
    #expect(read(target(tiles: [wrongWindow])) == nil)
  }

  @Test func refusesIncompleteMetadataWithoutGuessingAnotherWindow() {
    for key in ["fs_wid", "pid", "TileLayoutManager", "type"] {
      var raw = target()
      raw[key] = nil
      #expect(read(raw) == nil)
    }
    #expect(read(target(tiles: [])) == nil)
    var desktop = target()
    desktop["type"] = 0
    #expect(read(desktop) == nil)
  }

  @Test(arguments: [0, -1, Int(UInt32.max) + 1])
  func rejectsInvalidWindowIDs(_ window: Int) {
    #expect(read(target(window: window)) == nil)
  }

  @Test(arguments: [0, -1, Int(Int32.max) + 1])
  func rejectsInvalidProcessIDs(_ app: Int) {
    #expect(read(target(app: app)) == nil)
  }
}
