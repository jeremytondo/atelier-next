import AppKit
import ApplicationServices

enum MissionControl {
  /// Dock adds a group identified as `mc` to its Accessibility tree for as
  /// long as Mission Control is showing. Nil when Dock does not answer.
  static var isOpen: Bool? {
    guard
      let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        .first,
      var level = AXUIElementCreateApplication(dock.processIdentifier)
        .attribute(kAXChildrenAttribute) as? [AXUIElement]
    else { return nil }
    for _ in 0..<3 {
      if level.contains(where: { $0.attribute(kAXIdentifierAttribute) as? String == "mc" }) {
        return true
      }
      level = level.flatMap { $0.attribute(kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    }
    return false
  }
}
