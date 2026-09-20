import Synchronization
import Testing

@testable import MacOS

@Suite struct FullScreenTransitionTests {
  private let transition = FullScreenTransition(space: 2, display: "Main", origin: 1)

  private func display(current: UInt64 = 2) -> DisplaySpaces {
    DisplaySpaces(
      id: "Main", currentSpace: current,
      spaces: [Space(id: 1, isDesktop: true), Space(id: 2, isDesktop: false)])
  }

  @Test func repairsTheOriginWhenFocusNeverConfirms() async {
    let repairs = Mutex(0)
    let result = await transition.confirm(
      displays: { [display()] }, isFocused: { false },
      restoreOrigin: {
        repairs.withLock { $0 += 1 }
        return true
      },
      timeout: .milliseconds(25))
    #expect(repairs.withLock { $0 } == 1)
    guard case .uncertain = result else {
      Issue.record("An unconfirmed switch must fail")
      return
    }
  }

  @Test func repairsAfterCancellationWithoutClaimingArrival() async {
    let repairs = Mutex(0)
    let task = Task {
      await transition.confirm(
        displays: { [display()] },
        isFocused: {
          withUnsafeCurrentTask { $0?.cancel() }
          return false
        },
        restoreOrigin: {
          repairs.withLock { $0 += 1 }
          return true
        })
    }
    let result = await task.value
    #expect(repairs.withLock { $0 } == 1)
    guard case .uncertain = result else {
      Issue.record("A cancelled confirmation must fail")
      return
    }
  }

  @Test func repairsWhenTheDestinationDisappearsAfterActivation() async {
    let repairs = Mutex(0)
    let result = await transition.confirm(
      displays: {
        [
          DisplaySpaces(
            id: "Main", currentSpace: 3,
            spaces: [Space(id: 1, isDesktop: true), Space(id: 3, isDesktop: true)])
        ]
      },
      isFocused: {
        Issue.record("A missing destination must not be queried")
        return false
      },
      restoreOrigin: {
        repairs.withLock { $0 += 1 }
        return true
      })
    #expect(repairs.withLock { $0 } == 1)
    guard case .uncertain = result else {
      Issue.record("A missing destination must fail")
      return
    }
  }

  @Test func doesNotRepairAnOriginThatIsCurrent() async {
    let result = await transition.confirm(
      displays: { [display(current: 1)] }, isFocused: { false },
      restoreOrigin: {
        Issue.record("Must not change the current Space's focus")
        return true
      },
      timeout: .zero)
    guard case .uncertain = result else {
      Issue.record("A switch that did not arrive must fail")
      return
    }
  }

  @Test func rechecksTheOriginAfterAwaitingFocus() async {
    let returned = Mutex(false)
    let task = Task {
      await transition.confirm(
        displays: { [display(current: returned.withLock { $0 } ? 1 : 2)] },
        isFocused: {
          returned.withLock { $0 = true }
          withUnsafeCurrentTask { $0?.cancel() }
          return false
        },
        restoreOrigin: {
          Issue.record("Must not overwrite the user's switch back")
          return true
        })
    }
    let result = await task.value
    guard case .uncertain = result else {
      Issue.record("A superseded switch must fail")
      return
    }
  }

  @Test func doesNotRepairWithoutAnOffscreenOrigin() async {
    for snapshot in [[], [display()]] {
      _ = await FullScreenTransition(space: 2, display: "Main", origin: 9).confirm(
        displays: { snapshot }, isFocused: { false },
        restoreOrigin: {
          Issue.record("Unknown origin must not be repaired")
          return true
        },
        timeout: .zero)
    }
  }

  @Test(arguments: [false, true])
  func doesNotRepairAnOriginNowShownOnAnotherDisplay(_ focused: Bool) async {
    let result = await transition.confirm(
      displays: {
        [
          DisplaySpaces(id: "Main", currentSpace: 2, spaces: [Space(id: 2, isDesktop: false)]),
          DisplaySpaces(id: "Other", currentSpace: 1, spaces: [Space(id: 1, isDesktop: true)]),
        ]
      },
      isFocused: { focused },
      restoreOrigin: {
        Issue.record("Must not change focus on another display's visible Space")
        return true
      },
      timeout: focused ? .seconds(3) : .zero,
      settling: .zero)
    switch result {
    case .sent: #expect(focused)
    case .uncertain: #expect(!focused)
    default: Issue.record("Skipping origin repair must not change the arrival result")
    }
  }

  @Test func confirmsWithoutRepairWhenThereWasNoDifferentOriginApp() async {
    let result = await FullScreenTransition(space: 2, display: "Main", origin: nil).confirm(
      displays: { [display()] }, isFocused: { true },
      restoreOrigin: {
        Issue.record("No origin process was saved")
        return true
      },
      settling: .zero)
    guard case .sent = result else {
      Issue.record("A confirmed switch without an origin repair must succeed")
      return
    }
  }

  @Test(arguments: [true, false])
  func successfulArrivalRequiresSuccessfulRepair(_ repaired: Bool) async {
    let repairs = Mutex(0)
    let result = await transition.confirm(
      displays: { [display()] }, isFocused: { true },
      restoreOrigin: {
        repairs.withLock { $0 += 1 }
        return repaired
      },
      settling: .zero)
    #expect(repairs.withLock { $0 } == 1)
    switch result {
    case .sent: #expect(repaired)
    case .uncertain: #expect(!repaired)
    default: Issue.record("A posted switch must be confirmed or uncertain")
    }
  }
}
