import Foundation

/// Sends one of macOS's Space-switching shortcuts and watches for the switch.
/// A shortcut only just turned on may not be one Dock answers yet, so a press
/// that shows nothing is sent once more, but only a jump to a numbered
/// Desktop, which lands in the same place however often it is pressed, and
/// only while the Spaces are exactly as they were. A step is never repeated:
/// a second one would overshoot.
struct SpaceShortcutTransition: Sendable {
  let space: UInt64
  let display: String
  let expecting: [DisplaySpaces]

  func run(
    displays: @Sendable () -> [DisplaySpaces], post: @Sendable () -> Bool,
    canRetry: Bool, timeout: Duration = .seconds(3), retryAfter: Duration = .milliseconds(250)
  ) async -> SpaceDispatch {
    guard displays() == expecting else { return .changed }
    guard post() else { return .refused("Could not send macOS's Space-switching shortcut.") }
    let start = ContinuousClock.now
    var retried = false
    while ContinuousClock.now - start < timeout {
      let snapshot = displays()
      if snapshot.first(where: { $0.id == display })?.currentSpace == space { return .sent }
      guard snapshot == expecting else {
        return .uncertain("The Spaces changed while macOS was switching.")
      }
      if canRetry, !retried, ContinuousClock.now - start >= retryAfter {
        retried = true
        guard post() else { break }
      }
      do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
    }
    return .uncertain("macOS did not switch to the Space Atelier asked for.")
  }
}
