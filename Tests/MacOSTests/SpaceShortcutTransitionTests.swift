import Synchronization
import Testing

@testable import MacOS

@Suite struct SpaceShortcutTransitionTests {
  private func displays(current: UInt64 = 2) -> [DisplaySpaces] {
    [
      DisplaySpaces(
        id: "Main", currentSpace: current,
        spaces: [
          Space(id: 1, isDesktop: true), Space(id: 2, isDesktop: false),
          Space(id: 3, isDesktop: true),
        ])
    ]
  }

  private var transition: SpaceShortcutTransition {
    SpaceShortcutTransition(space: 1, display: "Main", expecting: displays())
  }

  @Test func aDelayedNativeRegistrationGetsOneAbsoluteRetry() async {
    let presses = Mutex(0)
    let result = await transition.run(
      displays: { displays(current: presses.withLock { $0 } >= 2 ? 1 : 2) },
      post: {
        presses.withLock { $0 += 1 }
        return true
      },
      canRetry: true, retryAfter: .zero)
    #expect(result == .sent)
    #expect(presses.withLock { $0 } == 2)
  }

  @Test func aSuccessfulFirstPressIsNotRepeated() async {
    let presses = Mutex(0)
    let result = await transition.run(
      displays: { displays(current: presses.withLock { $0 } > 0 ? 1 : 2) },
      post: {
        presses.withLock { $0 += 1 }
        return true
      },
      canRetry: true, retryAfter: .zero)
    #expect(result == .sent)
    #expect(presses.withLock { $0 } == 1)
  }

  @Test(arguments: [false, true])
  func anIgnoredShortcutHasABoundedNumberOfPresses(_ canRetry: Bool) async {
    let presses = Mutex(0)
    let result = await transition.run(
      displays: { displays() },
      post: {
        presses.withLock { $0 += 1 }
        return true
      },
      canRetry: canRetry, timeout: .milliseconds(40), retryAfter: .zero)
    guard case .uncertain = result else {
      Issue.record("An ignored shortcut must not report success")
      return
    }
    #expect(presses.withLock { $0 } == (canRetry ? 2 : 1))
  }

  @Test func aUserSwitchPreventsTheRetry() async {
    let presses = Mutex(0)
    let result = await transition.run(
      displays: { displays(current: presses.withLock { $0 } > 0 ? 3 : 2) },
      post: {
        presses.withLock { $0 += 1 }
        return true
      },
      canRetry: true, retryAfter: .zero)
    guard case .uncertain = result else {
      Issue.record("A superseded switch must not report success")
      return
    }
    #expect(presses.withLock { $0 } == 1)
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
