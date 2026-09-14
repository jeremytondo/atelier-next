import Foundation

/// Deadline polling over injected time, so one loop serves live macOS, where
/// it keeps the run loop serving events between checks, and tests, which
/// advance a fake clock instead of sleeping.
struct Poller {
  var now: () -> TimeInterval
  var pause: () -> Void

  static func live(interval: TimeInterval) -> Poller {
    Poller(
      now: { ProcessInfo.processInfo.systemUptime },
      pause: { RunLoop.current.run(until: Date().addingTimeInterval(interval)) })
  }

  /// True as soon as `condition` holds; false once `timeout` elapses without it.
  func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let started = now()
    repeat {
      if condition() { return true }
      pause()
    } while now() - started < timeout
    return condition()
  }

  /// True once `condition` has held continuously for `stableFor` seconds.
  func wait(_ timeout: TimeInterval, stableFor: TimeInterval, until condition: () -> Bool) -> Bool {
    let started = now()
    var since: TimeInterval?
    repeat {
      let time = now()
      if condition() {
        since = since ?? time
        if time - since! >= stableFor { return true }
      } else {
        since = nil
      }
      pause()
    } while now() - started < timeout
    return false
  }

  func sleep(_ seconds: TimeInterval) {
    let started = now()
    while now() - started < seconds { pause() }
  }
}
