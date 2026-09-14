// The pinned HS2 API only exposes activating launch. This transaction keeps
// launch/reopen, placement, All Desktops assignment, and final focus together so
// summoning an app cannot switch away before its membership has been established.
// General Group focus, Fill, shortcuts, and observation live in HS2 JavaScript.
import AppKit
import ApplicationServices

struct QuickAppState {
  var pid: Int32
  var window: UInt32
  var previous: NSRunningApplication?
  var previousWindow: UInt32
  var display: String
  var space: String
}

extension EngineBridge {
  private func quickPause() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.04))
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
      throw EngineError("Quick app refused window placement")
    }
  }

  private func quickVisibleFrame(_ displayID: CGDirectDisplayID) throws -> CGRect {
    guard
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == displayID
      }), let primary = NSScreen.screens.first
    else {
      throw EngineError("Quick app display disconnected")
    }
    let f = screen.visibleFrame
    return CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
  }

  private func placeQuickWindow(
    _ window: AXUIElement, on displayID: CGDirectDisplayID, size: QuickAppSize?
  ) throws {
    let usable = try quickVisibleFrame(displayID).insetBy(dx: 8, dy: 8)
    guard let old = frame(window) else {
      throw EngineError("Quick app window has no readable frame")
    }
    // Move without activation so the window reaches the captured display first.
    try setQuickPosition(
      window,
      CGPoint(
        x: usable.midX - min(old.width, usable.width) / 2,
        y: usable.midY - min(old.height, usable.height) / 2))
    if size != nil || old.width > usable.width || old.height > usable.height {
      var requested = CGSize(
        width: min(size?.width ?? old.width, usable.width),
        height: min(size?.height ?? old.height, usable.height))
      guard let value = AXValueCreate(.cgSize, &requested),
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
      else {
        throw EngineError("Quick app refused the requested size")
      }
    }
    // Recenter using the actual size: apps may impose their own minimum dimensions.
    for _ in 0..<20 {
      quickPause()
      guard let actual = frame(window) else { continue }
      let point = CGPoint(x: usable.midX - actual.width / 2, y: usable.midY - actual.height / 2)
      try setQuickPosition(window, point)
      quickPause()
      if let settled = frame(window),
        abs(settled.minX - point.x) < 3, abs(settled.minY - point.y) < 3,
        abs(settled.width - actual.width) < 3, abs(settled.height - actual.height) < 3
      {
        return
      }
    }
    throw EngineError("Quick app did not settle at the center of the captured display")
  }

  private func launch(_ target: TargetApplication) throws -> NSRunningApplication {
    // Request launch/reopen without taking focus or switching to an old Space.
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    var outcome: Result<NSRunningApplication, Error>?
    NSWorkspace.shared.openApplication(at: target.url, configuration: configuration) { app, error in
      DispatchQueue.main.async {
        if let app {
          outcome = .success(app)
        } else {
          outcome = .failure(error ?? EngineError("Could not launch \(target.name)"))
        }
      }
    }
    guard wait(10, until: { outcome != nil }), let outcome else {
      throw EngineError("Could not launch \(target.name)")
    }
    return try outcome.get()
  }

  func toggleQuickApp(_ request: QuickToggleRequest) throws -> QuickToggleResponse {
    let target = try TargetApplication.resolve(request.app)
    if let expected = request.expectedBundleID, expected != target.bundleIdentifier {
      throw EngineError(
        "The configured app identity changed. Review its app reference in init.js and reload.")
    }
    if let size = request.size {
      guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
        throw EngineError("Invalid quick app size")
      }
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
        throw EngineError("Could not hide \(target.name)")
      }
      guard wait(1, until: { running.isHidden }) else {
        throw EngineError("Could not verify quick app was hidden")
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
        restored = wait(1, until: { focusedID() == state.previousWindow })
      }
      quickStates[bundleID]?.previous = nil
      return QuickToggleResponse(action: .hidden, bundleID: bundleID, restoredFocus: restored)
    }

    let topology = runtime.snapshot()
    guard let display = resolver.resolve(in: topology),
      let desktop = topology.first(where: { $0.identifier == display.topologyIdentifier }),
      desktop.regularDesktops.contains(where: { $0.id == desktop.currentSpaceID })
    else {
      throw EngineError(
        "Quick apps require an ordinary Desktop; fullscreen and Split View are unsupported")
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
        throw EngineError("Active Desktop changed during quick app summon")
      }
    }
    let app: NSRunningApplication
    if let running, !quickWindows(running).isEmpty {
      app = running
    } else {
      app = try launch(target)
    }
    var selected: AXUIElement?
    _ = wait(
      4,
      until: {
        let windows = quickWindows(app)
        let remembered = quickStates[bundleID]
        selected =
          windows.first(where: {
            remembered?.pid == app.processIdentifier && id($0) == remembered?.window
          })
          ?? windows.first(where: { id($0) == focusedID() }) ?? windows.first
        return selected != nil
      })
    guard let window = selected else {
      throw EngineError(
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
        throw EngineError("Quick app window could not be unminimized")
      }
    }
    try placeQuickWindow(window, on: display.displayID, size: request.size)
    try checkDesktop()
    let expected = Set(desktop.regularDesktops.map { String($0.id) })
    let assignment = try quickAssignment.ensureAllDesktops(
      application: app, window: window, target: target, requiredSpaceIDs: expected)
    try checkDesktop()
    // Keep this identity even if later placement fails, allowing a second press to hide.
    quickStates[bundleID] = QuickAppState(
      pid: app.processIdentifier, window: id(window),
      previous: previous?.bundleIdentifier == bundleID ? nil : previous,
      previousWindow: previousWindow,
      display: display.topologyIdentifier, space: space)
    guard wait(1, until: { expected.isSubset(of: Set(spaces(id(window)))) }) else {
      throw EngineError("Quick app is not available on every Desktop of the captured display")
    }
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    app.activate(options: [])
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    let focused = wait(1.5, until: { focusedID() == id(window) })
    try checkDesktop()
    guard focused else { throw EngineError("Could not focus the quick app window") }
    return QuickToggleResponse(
      action: .shown, bundleID: bundleID, window: id(window),
      display: display.topologyIdentifier, space: space,
      frame: frame(window).map(Frame.init), assignment: assignment.message)
  }
}
