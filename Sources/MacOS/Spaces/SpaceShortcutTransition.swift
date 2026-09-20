import Foundation

/// Confirms a native shortcut while its registration remains available.
/// Enabling a shortcut does not ensure Dock has accepted the first key yet.
/// An absolute Desktop jump can be repeated once without overshooting; an
/// arrow cannot. Retry only while the complete original Space state remains.
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
    let arrived = expecting.map {
      $0.id == display ? DisplaySpaces(id: $0.id, currentSpace: space, spaces: $0.spaces) : $0
    }
    while ContinuousClock.now - start < timeout {
      let snapshot = displays()
      if snapshot == arrived { return .sent }
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
