// Wait briefly for native Dock reconciliation before considering a display
// refresh. The caller must reject changed topology and failed count queries.
import Foundation

public struct DockRegistration {
  public let confirmed: Bool
  public let milliseconds: Double
  public let counts: [Int]

  public static func observe(expectedCount: Int, read: () throws -> Int,
    now: () -> TimeInterval, pause: () -> Void) throws -> DockRegistration {
    let started = now()
    var matchingSince: TimeInterval?, counts: [Int] = []
    while true {
      let count = try read(), time = now()
      counts.append(count)
      if count == expectedCount { matchingSince = matchingSince ?? time }
      else { matchingSince = nil }
      let confirmed = matchingSince.map { time - $0 >= 0.05 } == true
      if confirmed || time - started >= 0.15 {
        return DockRegistration(confirmed: confirmed, milliseconds: (time - started) * 1000, counts: counts)
      }
      pause()
    }
  }
}
