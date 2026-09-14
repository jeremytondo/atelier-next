import SpaceControlCore
import Testing

private let displayA = DisplaySpaceSnapshot(
  identifier: "A",
  currentSpaceID: 1,
  spaces: [
    ManagedSpaceSnapshot(id: 1, isFullscreen: false),
    ManagedSpaceSnapshot(id: 90, isFullscreen: true),
    ManagedSpaceSnapshot(id: 2, isFullscreen: false),
  ]
)
private let displayB = DisplaySpaceSnapshot(
  identifier: "B",
  currentSpaceID: 10,
  spaces: [
    ManagedSpaceSnapshot(id: 10, isFullscreen: false),
    ManagedSpaceSnapshot(id: 11, isFullscreen: false),
  ]
)

@Test func perDisplayNumberingExcludesFullscreenSpaces() {
  let target = SpaceTopology.desktop(number: 2, on: "A", displays: [displayA, displayB])
  #expect(target?.id == 2)
  #expect(SpaceTopology.desktop(number: 3, on: "A", displays: [displayA, displayB]) == nil)
}

@Test func globalNumberingUsesRawDisplayOrderAndExcludesFullscreenSpaces() {
  #expect(SpaceTopology.globalDesktopNumber(for: 1, displays: [displayA, displayB]) == 1)
  #expect(SpaceTopology.globalDesktopNumber(for: 2, displays: [displayA, displayB]) == 2)
  #expect(SpaceTopology.globalDesktopNumber(for: 10, displays: [displayA, displayB]) == 3)
  #expect(SpaceTopology.globalDesktopNumber(for: 90, displays: [displayA, displayB]) == nil)
}

@Test func detectsExactlyOneNewRegularDesktop() {
  let after = DisplaySpaceSnapshot(
    identifier: "A",
    currentSpaceID: 1,
    spaces: displayA.spaces + [ManagedSpaceSnapshot(id: 3, isFullscreen: false)]
  )
  #expect(SpaceTopology.addedDesktop(on: "A", before: [displayA], after: [after])?.id == 3)
  #expect(SpaceTopology.addedDesktop(on: "B", before: [displayA], after: [after]) == nil)
}

@Test func ambiguousAddFailsClosed() {
  let after = DisplaySpaceSnapshot(
    identifier: "A",
    currentSpaceID: 1,
    spaces: displayA.spaces + [
      ManagedSpaceSnapshot(id: 3, isFullscreen: false),
      ManagedSpaceSnapshot(id: 4, isFullscreen: false),
    ]
  )
  #expect(SpaceTopology.addedDesktop(on: "A", before: [displayA], after: [after]) == nil)
}

@Test func decoderAcceptsKnownIDShapesAndMarksFullscreenSpaces() {
  let decoded = SpaceTopology.decode([
    [
      "Display Identifier": "Main",
      "Current Space": ["id64": 1],
      "Spaces": [
        ["ManagedSpaceID": 1, "type": 0],
        ["id64": 2, "type": 4],
        ["ManagedSpaceID": 3, "TileLayoutManager": ["layout": "full"]],
      ],
    ]
  ])

  #expect(decoded.count == 1)
  #expect(decoded[0].currentSpaceID == 1)
  #expect(decoded[0].spaces.map(\.isFullscreen) == [false, true, true])
  #expect(decoded[0].spaces.map(\.rawType) == [0, 4, nil])
}
