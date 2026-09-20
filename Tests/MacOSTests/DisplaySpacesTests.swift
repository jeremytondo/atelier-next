import Testing

@testable import MacOS

/// The dictionaries are shaped like SLSCopyManagedDisplaySpaces output.
@Suite struct DisplaySpacesTests {
  private func display(current: Int, spaces: [[String: Any]]) -> [String: Any] {
    [
      "Display Identifier": "Main", "Current Space": ["ManagedSpaceID": current, "type": 0],
      "Spaces": spaces,
    ]
  }

  @Test func tellsDesktopsFromFullScreenAndSplitViewSpaces() {
    let decoded = DisplaySpaces.decode([
      display(
        current: 7,
        spaces: [
          ["ManagedSpaceID": 3, "type": 0],
          ["ManagedSpaceID": 7, "type": 4, "TileLayoutManager": ["TileSpaces": [["id64": 8]]]],
          [
            "ManagedSpaceID": 9, "type": 4,
            "TileLayoutManager": ["TileSpaces": [["id64": 10], ["id64": 11]]],
          ],
        ])
    ])
    #expect(
      decoded == [
        DisplaySpaces(
          id: "Main", currentSpace: 7,
          spaces: [
            Space(id: 3, isDesktop: true), Space(id: 7, isDesktop: false),
            Space(id: 9, isDesktop: false),
          ])
      ])
  }

  @Test func namesFullScreenAndSplitViewSpacesByTheirApps() {
    func space(_ id: Int, apps: [Int]) -> [String: Any] {
      [
        "ManagedSpaceID": id, "type": 4,
        "TileLayoutManager": ["TileSpaces": apps.map { ["pid": $0] }],
      ]
    }
    let names = DisplaySpaces.names([
      display(
        current: 3,
        spaces: [
          ["ManagedSpaceID": 3, "type": 0],
          space(7, apps: [40]),
          // A pair is joined, and an app that cannot be named is left out.
          space(9, apps: [41, 42]),
          space(11, apps: [41, 99]),
          space(13, apps: [99]),
        ])
    ]) { [40: "Numbers", 41: "Notes", 42: "Safari"][$0] }
    #expect(names == [7: "Numbers", 9: "Notes & Safari", 11: "Notes"])
  }

  @Test func keepsEachDisplaysCurrentSpace() {
    var second = display(current: 5, spaces: [["id64": 5, "type": 0]])
    second["Display Identifier"] = "Second"
    let decoded = DisplaySpaces.decode([
      display(current: 1, spaces: [["ManagedSpaceID": 1, "type": 0]]), second,
    ])
    #expect(decoded.map(\.currentSpace) == [1, 5])
  }

  @Test func readsEverythingOrNothing() {
    // Places in the list are what Desktops are moved by, so a gap is not tolerated.
    let readable = display(current: 1, spaces: [["ManagedSpaceID": 1, "type": 0]])
    #expect(DisplaySpaces.decode([readable, ["Display Identifier": "Other"]]).isEmpty)
    #expect(
      DisplaySpaces.decode([
        display(current: 1, spaces: [["ManagedSpaceID": 1, "type": 0], ["type": 4]])
      ]).isEmpty)
    #expect(
      DisplaySpaces.decode([
        display(current: 1, spaces: [["ManagedSpaceID": 1, "type": 0], ["ManagedSpaceID": 2]])
      ]).isEmpty)
    #expect(
      DisplaySpaces.decode([display(current: 9, spaces: [["ManagedSpaceID": 1, "type": 0]])])
        .isEmpty)
    #expect(DisplaySpaces.decode([readable, readable]).isEmpty)
  }
}
