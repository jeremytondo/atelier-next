import Foundation

/// Whether a returned Desktop ID has become exactly one new ordinary Desktop.
public enum CreationObservation: Equatable, Sendable {
  case pending
  case verified
  case rejected(String)
}

extension SpaceTopology {
  /// Only an exact new managed type-0 Desktop on the target display, with every
  /// existing Space, its order, and each display's current Space unchanged,
  /// counts as created. Anything else is evidence to report, never to repair.
  public static func confirmCreation(
    id: UInt64,
    on displayIdentifier: String,
    before: [DisplaySpaceSnapshot],
    after: [DisplaySpaceSnapshot]
  ) -> CreationObservation {
    guard id > 0 else { return .rejected("macOS returned no Desktop ID") }
    let oldIDs = Set(before.flatMap { $0.spaces.map(\.id) })
    guard !oldIDs.contains(id) else { return .rejected("macOS returned an existing Desktop ID") }
    guard before.map(\.identifier) == after.map(\.identifier),
      before.contains(where: { $0.identifier == displayIdentifier })
    else { return .rejected("The display configuration changed during creation") }
    for (old, new) in zip(before, after) {
      guard new.spaces.filter({ oldIDs.contains($0.id) }) == old.spaces else {
        return .rejected("Existing Desktops changed order, type, or display during creation")
      }
      guard old.currentSpaceID == new.currentSpaceID else {
        return .rejected("The active Desktop changed during creation")
      }
    }
    let added = after.flatMap { display in
      display.spaces.filter { !oldIDs.contains($0.id) }.map { (display.identifier, $0) }
    }
    if added.isEmpty { return .pending }
    guard added.count == 1, added[0].1.id == id else {
      return .rejected("macOS reported a different or ambiguous Desktop addition")
    }
    guard added[0].0 == displayIdentifier else {
      return .rejected("The Desktop was created on another display")
    }
    guard added[0].1.rawType == 0, !added[0].1.isFullscreen else {
      return .rejected("The created Space is not an ordinary Desktop")
    }
    return .verified
  }

}

/// Dock keeps its own Desktop list and registers numbered shortcuts from it.
/// A created Space is usable only after that list agrees.
public struct DockRegistration: Equatable, Sendable {
  public let confirmed: Bool
  public let counts: [Int]
  public let seconds: TimeInterval

  /// Polls `read` until it returns `expectedCount` continuously for `stableFor`
  /// seconds, giving up after `timeout`. Errors from `read` propagate unchanged
  /// so callers can refuse when the topology moves underneath the wait.
  public static func observe(
    expectedCount: Int,
    stableFor: TimeInterval = 0.05,
    timeout: TimeInterval = 0.15,
    read: () throws -> Int,
    now: () -> TimeInterval,
    pause: () -> Void
  ) rethrows -> DockRegistration {
    let started = now()
    var matchingSince: TimeInterval?
    var counts: [Int] = []
    while true {
      let count = try read()
      let time = now()
      counts.append(count)
      matchingSince = count == expectedCount ? (matchingSince ?? time) : nil
      let confirmed = matchingSince.map { time - $0 >= stableFor } == true
      if confirmed || time - started >= timeout {
        return DockRegistration(confirmed: confirmed, counts: counts, seconds: time - started)
      }
      pause()
    }
  }
}
