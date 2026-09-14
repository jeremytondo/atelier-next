import Foundation
import SpaceControlCore
import Testing

private func desktop(_ id: UInt64, fullscreen: Bool = false) -> ManagedSpaceSnapshot {
  ManagedSpaceSnapshot(id: id, isFullscreen: fullscreen, rawType: fullscreen ? 4 : 0)
}
private let before = [
  DisplaySpaceSnapshot(identifier: "A", currentSpaceID: 2, spaces: [desktop(1), desktop(2), desktop(90, fullscreen: true)])
]
private func after(_ spaces: [ManagedSpaceSnapshot], current: UInt64 = 2, display: String = "A") -> [DisplaySpaceSnapshot] {
  [DisplaySpaceSnapshot(identifier: display, currentSpaceID: current, spaces: spaces)]
}

@Test func creationIsPendingUntilTheCensusChanges() {
  #expect(SpaceTopology.confirmCreation(id: 5, on: "A", before: before, after: before) == .pending)
}

@Test func creationIsVerifiedOnlyForTheExactNewOrdinaryDesktop() {
  let appended = after(before[0].spaces + [desktop(5)])
  #expect(SpaceTopology.confirmCreation(id: 5, on: "A", before: before, after: appended) == .verified)
  let inserted = after([desktop(1), desktop(2), desktop(5), desktop(90, fullscreen: true)])
  #expect(SpaceTopology.confirmCreation(id: 5, on: "A", before: before, after: inserted) == .verified)
}

@Test(arguments: [
  (UInt64(0), after(before[0].spaces + [desktop(5)]), "no Desktop ID"),
  (UInt64(2), after(before[0].spaces + [desktop(5)]), "existing Desktop ID"),
  (UInt64(5), after(before[0].spaces + [desktop(6)]), "different or ambiguous"),
  (UInt64(5), after(before[0].spaces + [desktop(5), desktop(6)]), "different or ambiguous"),
  (UInt64(5), after(before[0].spaces + [desktop(5, fullscreen: true)]), "not an ordinary Desktop"),
  (UInt64(5), after(before[0].spaces + [ManagedSpaceSnapshot(id: 5, isFullscreen: false)]), "not an ordinary Desktop"),
  (UInt64(5), after(before[0].spaces + [desktop(5)], current: 1), "active Desktop changed"),
  (UInt64(5), after([desktop(2), desktop(1), desktop(90, fullscreen: true), desktop(5)]), "changed order"),
  (UInt64(5), after([desktop(1), desktop(90, fullscreen: true), desktop(5)]), "changed order"),
  (UInt64(5), after(before[0].spaces + [desktop(5)], display: "B"), "display configuration changed"),
  (UInt64(5), before + after([desktop(5)], current: 5, display: "B"), "display configuration changed"),
])
func creationIsRejectedForEveryOtherTopologyChange(id: UInt64, topology: [DisplaySpaceSnapshot], reason: String) {
  guard case .rejected(let message) = SpaceTopology.confirmCreation(id: id, on: "A", before: before, after: topology) else {
    Issue.record("expected rejection containing \(reason)")
    return
  }
  #expect(message.contains(reason))
}

@Test func creationOnAnotherDisplayIsRejected() {
  let two = before + [DisplaySpaceSnapshot(identifier: "B", currentSpaceID: 10, spaces: [desktop(10)])]
  let elsewhere = [two[0], DisplaySpaceSnapshot(identifier: "B", currentSpaceID: 10, spaces: [desktop(10), desktop(5)])]
  #expect(SpaceTopology.confirmCreation(id: 5, on: "A", before: two, after: elsewhere) == .rejected("The Desktop was created on another display"))
}

private struct Clock {
  var time: TimeInterval = 0
}

@Test func dockRegistrationConfirmsAfterAStableWindow() {
  var clock = Clock()
  var reads = [3, 4, 4, 4, 4]
  let result = DockRegistration.observe(
    expectedCount: 4, read: { reads.isEmpty ? 4 : reads.removeFirst() },
    now: { clock.time }, pause: { clock.time += 0.02 })
  #expect(result.confirmed)
  #expect(result.counts == [3, 4, 4, 4, 4])
  #expect(result.seconds >= 0.05 && result.seconds < 0.15)
}

@Test func dockRegistrationRestartsTheWindowOnTransientMismatchAndTimesOut() {
  var clock = Clock()
  var reads = [4, 4, 3, 4, 4, 3, 4, 3, 4]
  let result = DockRegistration.observe(
    expectedCount: 4, read: { reads.isEmpty ? 3 : reads.removeFirst() },
    now: { clock.time }, pause: { clock.time += 0.02 })
  #expect(!result.confirmed)
  #expect(result.seconds >= 0.15)
}

@Test func dockRegistrationPropagatesReadFailures() {
  struct Moved: Error {}
  var clock = Clock()
  #expect(throws: Moved.self) {
    try DockRegistration.observe(expectedCount: 4, read: { throw Moved() }, now: { clock.time }, pause: { clock.time += 0.02 })
  }
}
