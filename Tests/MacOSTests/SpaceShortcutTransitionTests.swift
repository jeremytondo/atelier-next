import Synchronization
import Testing

@testable import MacOS

@Suite struct SpaceShortcutTransitionTests {
  private func displays(current: UInt64 = 2, other: UInt64 = 8) -> [DisplaySpaces] {
    [
      DisplaySpaces(
        id: "Main", currentSpace: current,
        spaces: [
          Space(id: 1, isDesktop: true), Space(id: 2, isDesktop: false),
          Space(id: 3, isDesktop: true),
        ]),
      DisplaySpaces(
        id: "Other", currentSpace: other,
        spaces: [Space(id: 8, isDesktop: true), Space(id: 9, isDesktop: true)]),
    ]
  }

  private var transition: SpaceShortcutTransition {
    SpaceShortcutTransition(space: 1, display: "Main", expecting: displays())
  }

  /// Runs with every press accepted; `showing` is the Spaces after that many.
  private func run(
    canRetry: Bool = true, timeout: Duration = .seconds(3),
    showing: @escaping @Sendable (_ presses: Int) -> [DisplaySpaces]
  ) async -> (result: SpaceDispatch, presses: Int) {
    let presses = Mutex(0)
    let result = await transition.run(
      displays: { showing(presses.withLock { $0 }) },
      post: {
        presses.withLock { $0 += 1 }
        return true
      },
      canRetry: canRetry, timeout: timeout, retryAfter: .zero)
    return (result, presses.withLock { $0 })
  }

  @Test func anIgnoredJumpIsPressedOnceMore() async {
    let (result, presses) = await run { displays(current: $0 >= 2 ? 1 : 2) }
    #expect(result == .sent)
    #expect(presses == 2)
  }

  @Test func aPressThatShowsIsNotRepeated() async {
    let (result, presses) = await run { displays(current: $0 > 0 ? 1 : 2) }
    #expect(result == .sent)
    #expect(presses == 1)
  }

  @Test func arrivalCountsWhateverElseChanged() async {
    let (result, presses) = await run {
      $0 > 0 ? displays(current: 1, other: 9) : displays()
    }
    #expect(result == .sent)
    #expect(presses == 1)
  }

  @Test(arguments: [false, true])
  func aShortcutMacOSIgnoresIsPressedTwiceAtMost(_ canRetry: Bool) async {
    let (result, presses) = await run(canRetry: canRetry, timeout: .milliseconds(40)) { _ in
      displays()
    }
    guard case .uncertain = result else {
      Issue.record("An ignored shortcut must not report success")
      return
    }
    #expect(presses == (canRetry ? 2 : 1))
  }

  @Test func aSwitchElsewhereStopsTheRetry() async {
    let (result, presses) = await run { displays(current: $0 > 0 ? 3 : 2) }
    guard case .uncertain = result else {
      Issue.record("A superseded switch must not report success")
      return
    }
    #expect(presses == 1)
  }

  @Test func changedSpacesAreNotActedOn() async {
    let result = await transition.run(
      displays: { displays(current: 3) },
      post: {
        Issue.record("A stale selection must send no keys")
        return true
      }, canRetry: true)
    #expect(result == .changed)
  }

  @Test func aFailureToPostIsReported() async {
    let result = await transition.run(displays: { displays() }, post: { false }, canRetry: true)
    guard case .refused = result else {
      Issue.record("Failure to post must not report success")
      return
    }
  }
}
