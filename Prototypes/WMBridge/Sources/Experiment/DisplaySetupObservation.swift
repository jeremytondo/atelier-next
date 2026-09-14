// Observe the same one-second post-release interval while other work proceeds.
// Missing window information is uncertainty, never evidence that no UI appeared.
import AppKit

final class DisplaySetupObservation {
  private let initial: Set<UInt32>
  private var seen = Set<UInt32>()
  private var queryComplete: Bool
  private var timer: Timer?
  private var started: TimeInterval?
  private var deadline: TimeInterval = 0

  private static func windows() -> Set<UInt32>? {
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
    return Set(windows.compactMap {
      guard let pid = $0[kCGWindowOwnerPID as String] as? Int32,
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.controlcenter.helper" else { return nil }
      return $0[kCGWindowNumber as String] as? UInt32
    })
  }
  init() {
    let windows = Self.windows()
    initial = windows ?? []
    queryComplete = windows != nil
  }
  deinit { timer?.invalidate() }
  func sample() {
    guard let windows = Self.windows() else { queryComplete = false; return }
    seen.formUnion(windows.subtracting(initial))
  }
  var clear: Bool { queryComplete && seen.isEmpty }
  var report: [String: Any] {
    ["newSetupWindows": seen.sorted(), "setupUIObserved": !seen.isEmpty, "queryComplete": queryComplete,
      "observationMilliseconds": started.map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 } ?? 0]
  }
  func start(seconds: TimeInterval) {
    started = ProcessInfo.processInfo.systemUptime
    deadline = started! + seconds
    timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in self?.sample() }
  }
  @discardableResult func finish() -> [String: Any] {
    while ProcessInfo.processInfo.systemUptime < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    sample()
    timer?.invalidate()
    timer = nil
    return report
  }
}
