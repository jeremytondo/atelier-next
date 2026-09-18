import Testing

@testable import MacOS

/// Spaces are numbered from 1 in order; `notDesktops` are full-screen or
/// Split View Spaces. Every shortcut is switched on unless a test says which
/// are `off`.
@Suite struct SpaceRouteTests {
  private func display(
    _ spaces: ClosedRange<UInt64>, notDesktops: Set<UInt64> = [], current: UInt64,
    id: String = "only"
  ) -> DisplaySpaces {
    DisplaySpaces(
      id: id, currentSpace: current,
      spaces: spaces.map { Space(id: $0, isDesktop: !notDesktops.contains($0)) })
  }

  private func presses(
    to target: UInt64, on id: String = "only", in displays: [DisplaySpaces],
    off: (SpaceRoute.Press) -> Bool = { _ in false }
  ) -> [SpaceRoute.Press]? {
    SpaceRoute.plan(to: target, on: id, in: displays) { !off($0) }?.map(\.press)
  }

  /// As on a Mac where "Switch to Desktop N" was never turned on.
  private func numberedOff(_ press: SpaceRoute.Press) -> Bool {
    if case .desktop = press { true } else { false }
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
      to: 5, on: "only", in: [display(1...5, notDesktops: [2, 5], current: 1)]
    ) { _ in true }
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

  @Test func withTheNumberedShortcutsOffEveryDesktopIsReachedByStepping() {
    // Pressing a shortcut that is off does nothing, so it is never pressed.
    let displays = [display(1...6, current: 1)]
    #expect(presses(to: 2, in: displays, off: numberedOff) == [.next])
    #expect(presses(to: 4, in: displays, off: numberedOff) == [.next, .next, .next])
    let last = [display(1...6, current: 6)]
    #expect(presses(to: 4, in: last, off: numberedOff) == [.previous, .previous])
    let plan = SpaceRoute.plan(to: 3, on: "only", in: displays) { !numberedOff($0) }
    #expect(plan?.map(\.arrivesAt) == [2, 3])
  }

  @Test func onlyTheNumberedShortcutsThatAreOnAreUsed() {
    // Desktop 3's is on and the rest are off: a jump there, then steps.
    let displays = [display(1...6, current: 1)]
    let onlyThree: (SpaceRoute.Press) -> Bool = { press in
      if case .desktop(let number) = press { number != 3 } else { false }
    }
    #expect(presses(to: 3, in: displays, off: onlyThree) == [.desktop(3)])
    #expect(presses(to: 5, in: displays, off: onlyThree) == [.desktop(3), .next, .next])
    #expect(presses(to: 2, in: displays, off: onlyThree) == [.next])
  }

  @Test func withSteppingOffOnlyAJumpAloneWillDo() {
    let steppingOff: (SpaceRoute.Press) -> Bool = { $0 == .next || $0 == .previous }
    let displays = [display(1...5, notDesktops: [2, 5], current: 1)]
    #expect(presses(to: 4, in: displays, off: steppingOff) == [.desktop(3)])
    // Space 5 is not a Desktop, so it has no number and cannot be stepped to.
    #expect(presses(to: 5, in: displays, off: steppingOff) == nil)
    // One direction off leaves the other, which may mean going round: past
    // Space 2 to the Desktop after it, and back a step.
    #expect(presses(to: 2, in: displays, off: { $0 == .previous }) == [.next])
    #expect(presses(to: 2, in: displays, off: { $0 == .next }) == [.desktop(2), .previous])
  }

  @Test func withEveryShortcutOffThereIsNoRouteButStayingPut() {
    let displays = [display(1...3, current: 2)]
    #expect(presses(to: 3, in: displays, off: { _ in true }) == nil)
    #expect(presses(to: 2, in: displays, off: { _ in true }) == [])
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
    // And so with the numbered shortcuts off there is no safe route at all.
    #expect(presses(to: 5, on: "second", in: displays, off: numberedOff) == nil)
  }
}
