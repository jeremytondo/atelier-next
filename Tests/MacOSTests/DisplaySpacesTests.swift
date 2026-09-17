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
          currentSpace: 7,
          spaces: [
            Space(id: 3, isDesktop: true), Space(id: 7, isDesktop: false),
            Space(id: 9, isDesktop: false),
          ])
      ])
  }

  @Test func keepsEachDisplaysCurrentSpace() {
    let decoded = DisplaySpaces.decode([
      display(current: 1, spaces: [["ManagedSpaceID": 1, "type": 0]]),
      display(current: 5, spaces: [["id64": 5, "type": 0]]),
    ])
    #expect(decoded.map(\.currentSpace) == [1, 5])
  }

  @Test func skipsWhatItCannotRead() {
    #expect(DisplaySpaces.decode([["Display Identifier": "Main"]]).isEmpty)
  }
}
