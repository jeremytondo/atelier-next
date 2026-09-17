import ApplicationServices

extension WindowCensus {
  /// Asks for exactly this window, not merely its app, to come forward.
  /// Size and position are left alone. Each request to the app is bounded, so
  /// a frozen app costs a few time limits and is reported as unanswered.
  func raise(window id: UInt32, of pid: pid_t) async -> RaiseResult {
    await Background.run {
      let app = AXUIElementCreateApplication(pid)
      guard let windows = app.attribute(kAXWindowsAttribute) as? [AXUIElement] else {
        return .unanswered
      }
      guard let window = windows.first(where: { skyLight.windowID(of: $0) == id }) else {
        return .closed
      }
      if app.attribute(kAXHiddenAttribute) as? Bool == true {
        app.set(kAXHiddenAttribute, false)
      }
      if window.attribute(kAXMinimizedAttribute) as? Bool == true {
        window.set(kAXMinimizedAttribute, false)
      }
      app.set(kAXFrontmostAttribute, true)
      window.set(kAXMainAttribute, true)
      AXUIElementPerformAction(window, kAXRaiseAction as CFString)
      return .asked
    }
  }
}
