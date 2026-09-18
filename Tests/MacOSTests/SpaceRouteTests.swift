import Testing

@testable import MacOS

/// Spaces are numbered from 1 in order; `notDesktops` are full-screen or
/// Split View Spaces.
@Suite struct SpaceRouteTests {
  private func display(
    _ spaces: ClosedRange<UInt64>, notDesktops: Set<UInt64> = [], current: UInt64,
    id: String = "only"
  ) -> DisplaySpaces {
    DisplaySpaces(
      id: id, currentSpace: current,
      spaces: spaces.map { Space(id: $0, isDesktop: !notDesktops.contains($0)) })
  }

  private func presses(to target: UInt64, on id: String = "only", in displays: [DisplaySpaces])
    -> [SpaceRoute.Press]?
  {
    SpaceRoute.plan(to: target, on: id, in: displays)?.map(\.press)
  }

  @Test func aNumberedDesktopIsOnePressFromAnywhere() {
    let displays = [display(1...5, notDesktops: [2, 5], current: 5)]
    #expect(presses(to: 1, in: displays) == [.desktop(1)])
    #expect(presses(to: 4, in: displays) == [.desktop(3)])
  }

  @Test func aSpaceThatIsNotADesktopIsReachedFromTheNearestWay() {
    let displays = [display(1...5, notDesktops: [2, 5], current: 1)]
    #expect(presses(to: 2, in: displays) == [.next])
    #expect(presses(to: 5, in: displays) == [.desktop(3), .next])
  }

  @Test func everyPressSaysWhereItShouldArrive() {
    let plan = SpaceRoute.plan(
      to: 5, on: "only", in: [display(1...5, notDesktops: [2, 5], current: 1)])
    #expect(plan?.map(\.arrivesAt) == [4, 5])
  }

  @Test func aDesktopPastTheNumberedShortcutsIsReachedByStepping() {
    #expect(
      presses(to: 18, in: [display(1...18, current: 1)]) == [.desktop(16), .next, .next])
  }

  @Test func theCurrentSpaceNeedsNoPress() {
    #expect(presses(to: 3, in: [display(1...3, current: 3)]) == [])
  }

  @Test func anUnknownSpaceOrDisplayHasNoRoute() {
    let displays = [display(1...3, current: 1)]
    #expect(presses(to: 9, in: displays) == nil)
    #expect(presses(to: 2, on: "other", in: displays) == nil)
  }

  @Test func withTwoDisplaysDesktopsAreNumberedAcrossBoth() {
    let displays = [
      display(1...2, current: 1, id: "first"),
      display(3...5, notDesktops: [4], current: 4, id: "second"),
    ]
    #expect(presses(to: 3, on: "second", in: displays) == [.desktop(3)])
    #expect(presses(to: 5, on: "second", in: displays) == [.desktop(4)])
  }

  @Test func withTwoDisplaysNothingIsReachedByStepping() {
    // Stepping acts on the display under the pointer, which may be the other one.
    let displays = [
      display(1...2, current: 1, id: "first"),
      display(3...5, notDesktops: [4], current: 3, id: "second"),
    ]
    #expect(presses(to: 4, on: "second", in: displays) == nil)
  }
}
