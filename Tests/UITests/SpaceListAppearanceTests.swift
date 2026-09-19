import AtelierKit
import Testing

@testable import UI

/// When the list of Spaces shows during a hold, with no clock: whoever keeps
/// the time says when the delay has passed.
@Suite struct SpaceListAppearanceTests {
  private let held = SpaceListHold.held(delay: .milliseconds(200))

  private func appearance(after events: (inout SpaceListAppearance) -> Void)
    -> SpaceListAppearance.Phase
  {
    var appearance = SpaceListAppearance()
    events(&appearance)
    return appearance.phase
  }

  @Test func appearsOnceTheKeysHaveBeenHeldForTheDelay() {
    #expect(appearance { $0.keys(held) } == .waiting(.milliseconds(200)))
    #expect(
      appearance {
        $0.keys(held)
        $0.delayPassed()
      } == .shown)
  }

  @Test func withNoDelayItAppearsAtOnce() {
    #expect(appearance { $0.keys(.held(delay: .zero)) } == .shown)
  }

  @Test func keysReleasedBeforeTheDelayShowNothingEvenWhenTheClockIsLate() {
    #expect(
      appearance {
        $0.keys(held)
        $0.keys(.released)
        $0.delayPassed()
      } == .released)
  }

  @Test func releasingTheKeysHidesTheList() {
    #expect(
      appearance {
        $0.keys(held)
        $0.delayPassed()
        $0.keys(.released)
      } == .released)
  }

  @Test func otherModifiersHideTheListAndTheWaitStartsOverWithout() {
    var appearance = SpaceListAppearance()
    appearance.keys(held)
    appearance.delayPassed()
    // Command joins Option: the window list's turn.
    appearance.keys(.suppressed)
    #expect(appearance.phase == .suppressed)
    appearance.delayPassed()
    #expect(appearance.phase == .suppressed)
    appearance.keys(held)
    #expect(appearance.phase == .waiting(.milliseconds(200)))
    appearance.delayPassed()
    #expect(appearance.phase == .shown)
  }

  @Test func aHoldCanStartSuppressed() {
    #expect(
      appearance {
        $0.keys(.suppressed)
        $0.keys(held)
      } == .waiting(.milliseconds(200)))
  }

  @Test(arguments: [false, true])
  func aDismissalLastsUntilTheKeysAreReleasedAndHeldAgain(shown: Bool) {
    var appearance = SpaceListAppearance()
    appearance.keys(held)
    if shown { appearance.delayPassed() }
    // A Space was chosen, or the leader opened, before or after the list appeared.
    appearance.dismiss()
    #expect(appearance.phase == .dismissed)
    // The clock, the command finishing, Shift, other modifiers: none brings it back.
    appearance.delayPassed()
    appearance.keys(held)
    appearance.keys(.suppressed)
    appearance.keys(held)
    appearance.delayPassed()
    #expect(appearance.phase == .dismissed)
    appearance.keys(.released)
    appearance.keys(held)
    #expect(appearance.phase == .waiting(.milliseconds(200)))
  }

  @Test func aDismissalWhileTheListIsSuppressedLastsToo() {
    #expect(
      appearance {
        $0.keys(.suppressed)
        $0.dismiss()
        $0.keys(held)
        $0.delayPassed()
      } == .dismissed)
  }

  @Test func withTheKeysUpThereIsNothingToDismiss() {
    #expect(
      appearance {
        $0.dismiss()
        $0.keys(held)
      } == .waiting(.milliseconds(200)))
  }
}
