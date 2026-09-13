// The pinned HS2 API only exposes activating launch. This transaction keeps
// launch/reopen, placement, All Desktops assignment, and final focus together so
// summoning an app cannot switch away before its membership has been established.
// General Group focus, Fill, shortcuts, and observation live in HS2 JavaScript.
import AppKit
import ApplicationServices
import QuickAppSupport

struct QuickAppState {
  var pid: Int32
  var window: UInt32
  var previous: NSRunningApplication?
  var previousWindow: UInt32
  var display: String
  var space: String
}

extension EngineBridge {
  private func quickPause() async throws {
    try await Task.sleep(for: .milliseconds(40))
  }

  private func quickWindows(_ app: NSRunningApplication) -> [AXUIElement] {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.35)
    return (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
      attribute($0, kAXRoleAttribute) as? String == kAXWindowRole
        && [kAXStandardWindowSubrole, kAXDialogSubrole].contains(
          attribute($0, kAXSubroleAttribute) as? String ?? "")
        && attribute($0, "AXModal") as? Bool != true
        && attribute($0, "AXFullScreen") as? Bool != true
    }
  }

  private func setQuickPosition(_ window: AXUIElement, _ point: CGPoint) throws {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point),
      AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    else {
      throw BridgeError(message: "Quick app refused window placement")
    }
  }

  private func quickVisibleFrame(_ displayID: CGDirectDisplayID) throws -> CGRect {
    guard
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == displayID
      }), let primary = NSScreen.screens.first
    else {
      throw BridgeError(message: "Quick app display disconnected")
    }
    let f = screen.visibleFrame
    return CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
  }

  private func placeQuickWindow(
    _ window: AXUIElement, on displayID: CGDirectDisplayID,
    size: [String: Double]?
  ) async throws {
    let usable = try quickVisibleFrame(displayID).insetBy(dx: 8, dy: 8)
    guard let old = frame(window), let width = old["w"], let height = old["h"] else {
      throw BridgeError(message: "Quick app window has no readable frame")
    }
    // Move without activation so the window reaches the captured display first.
    try setQuickPosition(
      window,
      CGPoint(
        x: usable.midX - min(width, usable.width) / 2,
        y: usable.midY - min(height, usable.height) / 2))
    if size != nil || width > usable.width || height > usable.height {
      var requested = CGSize(
        width: min(size?["width"] ?? width, usable.width),
        height: min(size?["height"] ?? height, usable.height))
      guard let value = AXValueCreate(.cgSize, &requested),
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
      else {
        throw BridgeError(message: "Quick app refused the requested size")
      }
    }
    // Recenter using the actual size: apps may impose their own minimum dimensions.
    for _ in 0..<20 {
      try await quickPause()
      guard let actual = frame(window), let w = actual["w"], let h = actual["h"] else { continue }
      let point = CGPoint(x: usable.midX - w / 2, y: usable.midY - h / 2)
      try setQuickPosition(window, point)
      try await quickPause()
      if let settled = frame(window),
        abs((settled["x"] ?? .infinity) - point.x) < 3,
        abs((settled["y"] ?? .infinity) - point.y) < 3,
        abs((settled["w"] ?? 0) - w) < 3, abs((settled["h"] ?? 0) - h) < 3
      {
        return
      }
    }
    throw BridgeError(message: "Quick app did not settle at the center of the captured display")
  }

  func toggleQuickApp(_ request: [String: Any]) async throws -> [String: Any] {
    guard let name = request["app"] as? String else { throw BridgeError(message: "app required") }
    let target = try TargetApplication.resolve(name)
    if let expected = request["expectedBundleID"] as? String, expected != target.bundleIdentifier {
      throw BridgeError(
        message:
          "The configured app identity changed. Review its app reference in init.js and reload.")
    }
    let size = request["size"] as? [String: Double]
    if request["size"] != nil {
      guard let size, let w = size["width"], let h = size["height"],
        w.isFinite, h.isFinite, w > 0, h > 0
      else { throw BridgeError(message: "Invalid quick app size") }
    }
    let bundleID = target.bundleIdentifier
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    if let running, !running.isHidden,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier,
      quickWindows(running).contains(where: {
        attribute($0, kAXMinimizedAttribute) as? Bool != true
      })
    {
      let appElement = AXUIElementCreateApplication(running.processIdentifier)
      guard
        running.hide()
          || AXUIElementSetAttributeValue(
            appElement, kAXHiddenAttribute as CFString, kCFBooleanTrue) == .success
      else {
        throw BridgeError(message: "Could not hide \(target.name)")
      }
      let deadline = Date().addingTimeInterval(1)
      while !running.isHidden && Date() < deadline { try await quickPause() }
      guard running.isHidden else {
        throw BridgeError(message: "Could not verify quick app was hidden")
      }
      var restored = false
      if let state = quickStates[bundleID], state.pid == running.processIdentifier,
        let previous = state.previous, !previous.isTerminated,
        runtime.snapshot().first(where: { $0.identifier == state.display }).map({
          String($0.currentSpaceID)
        }) == state.space,
        spaces(state.previousWindow).contains(state.space),
        let window = element(pid: previous.processIdentifier, window: state.previousWindow),
        attribute(window, kAXMinimizedAttribute) as? Bool != true
      {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        previous.activate(options: [])
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let deadline = Date().addingTimeInterval(1)
        while focusedID() != state.previousWindow && Date() < deadline { try await quickPause() }
        restored = focusedID() == state.previousWindow
      }
      quickStates[bundleID]?.previous = nil
      return ["action": "hidden", "bundleID": bundleID, "restoredFocus": restored]
    }

    let topology = runtime.snapshot()
    guard let display = resolver.resolve(in: topology),
      let desktop = topology.first(where: { $0.identifier == display.topologyIdentifier }),
      desktop.regularDesktops.contains(where: { $0.id == desktop.currentSpaceID })
    else {
      throw BridgeError(
        message: "Quick apps require an ordinary Desktop; fullscreen and Split View are unsupported"
      )
    }
    let space = String(desktop.currentSpaceID)
    let frontmost = NSWorkspace.shared.frontmostApplication
    let remembered = quickStates[bundleID]
    let reusePrevious =
      frontmost?.bundleIdentifier == bundleID && remembered?.display == display.topologyIdentifier
      && remembered?.space == space
    let previous = reusePrevious ? remembered?.previous : frontmost
    let previousWindow = reusePrevious ? (remembered?.previousWindow ?? 0) : focusedID()
    func checkDesktop() throws {
      guard
        runtime.snapshot().first(where: { $0.identifier == display.topologyIdentifier }).map({
          String($0.currentSpaceID)
        }) == space
      else {
        throw BridgeError(message: "Active Desktop changed during quick app summon")
      }
    }
    var app = running
    if app == nil || quickWindows(app!).isEmpty {
      // Request launch/reopen without taking focus or switching to an old Space.
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      app = try await NSWorkspace.shared.openApplication(
        at: target.url, configuration: configuration)
    }
    guard let app else { throw BridgeError(message: "Could not launch \(target.name)") }
    var selected: AXUIElement?
    let deadline = Date().addingTimeInterval(4)
    repeat {
      let windows = quickWindows(app)
      let remembered = quickStates[bundleID]
      selected =
        windows.first(where: {
          remembered?.pid == app.processIdentifier && id($0) == remembered?.window
        })
        ?? windows.first(where: { id($0) == focusedID() }) ?? windows.first
      if selected != nil { break }
      try await quickPause()
    } while Date() < deadline
    guard let window = selected else {
      throw BridgeError(
        message:
          "\(target.name) did not expose a standard window; close fullscreen mode or open its main window"
      )
    }
    try checkDesktop()
    // Hidden apps may have no queryable Space membership. Unhide without activating
    // before assignment; only focus after membership on the captured Desktop is verified.
    if !app.unhide() {
      AXUIElementSetAttributeValue(
        AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute as CFString,
        kCFBooleanFalse)
    }
    if attribute(window, kAXMinimizedAttribute) as? Bool == true {
      guard
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
          == .success
      else {
        throw BridgeError(message: "Quick app window could not be unminimized")
      }
    }
    try await placeQuickWindow(window, on: display.displayID, size: size)
    try checkDesktop()
    let expected = Set(desktop.regularDesktops.map { String($0.id) })
    let assignment = try await quickAssignment.ensureAllDesktops(
      application: app, window: window, target: target, requiredSpaceIDs: expected)
    try checkDesktop()
    // Keep this identity even if later placement fails, allowing a second press to hide.
    quickStates[bundleID] = QuickAppState(
      pid: app.processIdentifier, window: id(window),
      previous: previous?.bundleIdentifier == bundleID ? nil : previous,
      previousWindow: previousWindow,
      display: display.topologyIdentifier, space: space)
    let membershipDeadline = Date().addingTimeInterval(1)
    while !expected.isSubset(of: Set(spaces(id(window)))) && Date() < membershipDeadline {
      try await quickPause()
    }
    guard expected.isSubset(of: Set(spaces(id(window)))) else {
      throw BridgeError(
        message: "Quick app is not available on every Desktop of the captured display")
    }
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    app.activate(options: [])
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    let focusDeadline = Date().addingTimeInterval(1.5)
    while focusedID() != id(window) && Date() < focusDeadline { try await quickPause() }
    try checkDesktop()
    guard focusedID() == id(window) else {
      throw BridgeError(message: "Could not focus the quick app window")
    }
    return [
      "action": "shown", "bundleID": bundleID, "window": id(window),
      "display": display.topologyIdentifier,
      "space": space, "frame": frame(window) ?? [:], "assignment": assignment.message,
    ]
  }
}
