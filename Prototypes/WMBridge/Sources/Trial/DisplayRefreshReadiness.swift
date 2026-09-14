// A display callback is not proof of readiness. Require a completed, quiet
// callback batch AND a fresh match of Dock, Space, and display configuration.
import Foundation

public struct DisplayRefreshReadiness {
  private var pending = Set<UInt32>()
  private var completed = false
  private var lastEvent: TimeInterval?
  public init() {}
  public mutating func record(display: UInt32, beginning: Bool, at time: TimeInterval) {
    lastEvent = time
    if beginning { pending.insert(display) }
    else { pending.remove(display); completed = true }
  }
  public func isReady(at time: TimeInterval, stateMatches: Bool) -> Bool {
    stateMatches && completed && pending.isEmpty && lastEvent.map { time - $0 >= 0.05 } == true
  }
}
