import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension QuickAppSeams {
  /// The live macOS behavior behind QuickApps.
  @MainActor
  static func live(
    runtime: SpaceRuntime, resolver: TargetDisplayResolver, windows: WindowInventory,
    assignment: SpaceAssignment, poller: Poller
  ) -> QuickAppSeams {
    let elements = WindowElements(inventory: windows)
    func app(_ pid: pid_t) -> NSRunningApplication? {
      NSRunningApplication(processIdentifier: pid)
    }
    return QuickAppSeams(
      topology: { runtime.snapshot() },
      targetDisplay: { resolver.resolve(in: $0) },
      resolve: { try TargetApplication.resolve($0) },
      running: {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?
          .processIdentifier
      },
      frontmost: {
        NSWorkspace.shared.frontmostApplication.map {
          RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier)
        }
      },
      isRunning: { app($0)?.isTerminated == false },
      isHidden: { app($0)?.isHidden ?? true },
      hide: { pid in
        app(pid)?.hide() == true
          || AXUIElement.application(pid).set(kAXHiddenAttribute, kCFBooleanTrue)
      },
      unhide: { pid in
        if app(pid)?.unhide() != true {
          AXUIElement.application(pid).set(kAXHiddenAttribute, kCFBooleanFalse)
        }
      },
      launch: { target in try launch(target, poller: poller) },
      windows: { elements.eligibleWindows(of: $0) },
      isMinimized: { elements[$0]?.bool(kAXMinimizedAttribute) == true },
      unminimize: { elements[$0]?.set(kAXMinimizedAttribute, kCFBooleanFalse) == true },
      frame: { elements[$0]?.frame },
      move: { id, point in elements[id]?.set(kAXPositionAttribute, point: point) == true },
      resize: { id, size in elements[id]?.set(kAXSizeAttribute, size: size) == true },
      focus: { pid, id in
        elements[id]?.set(kAXMainAttribute, kCFBooleanTrue)
        app(pid)?.activate(options: [])
        elements[id]?.perform(kAXRaiseAction)
      },
      focusedWindow: { windows.focusedWindowID() },
      spaces: { windows.spaces(of: $0) },
      visibleFrame: visibleFrame,
      assignToAllDesktops: { pid, window, target, required in
        try assignment.ensureAllDesktops(
          pid: pid, window: window, target: target, requiredSpaceIDs: required
        ).message
      },
      poller: poller)
  }

  /// Requests launch or reopen without taking focus or switching to an old Space.
  @MainActor
  private static func launch(_ target: TargetApplication, poller: Poller) throws -> pid_t {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    var outcome: Result<pid_t, Error>?
    NSWorkspace.shared.openApplication(at: target.url, configuration: configuration) { app, error in
      DispatchQueue.main.async {
        if let app {
          outcome = .success(app.processIdentifier)
        } else {
          outcome = .failure(error ?? EngineError("Could not launch \(target.name)"))
        }
      }
    }
    guard poller.wait(10, until: { outcome != nil }), let outcome else {
      throw EngineError("Could not launch \(target.name)")
    }
    return try outcome.get()
  }

  /// AppKit's bottom-left visible frame converted to the top-left coordinates
  /// Accessibility positions windows in.
  private static func visibleFrame(_ displayID: CGDirectDisplayID) -> CGRect? {
    guard
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == displayID
      }), let primary = NSScreen.screens.first
    else { return nil }
    let visible = screen.visibleFrame
    return CGRect(
      x: visible.minX, y: primary.frame.maxY - visible.maxY, width: visible.width,
      height: visible.height)
  }
}

/// The Accessibility elements behind the window IDs handed to QuickApps, kept
/// from the most recent enumeration so later reads and writes need no lookup.
private final class WindowElements {
  private let inventory: WindowInventory
  private var byID: [UInt32: AXUIElement] = [:]

  init(inventory: WindowInventory) {
    self.inventory = inventory
  }

  func eligibleWindows(of pid: pid_t) -> [UInt32] {
    byID = [:]
    var ids: [UInt32] = []
    for window in AXUIElement.application(pid).elements(kAXWindowsAttribute) {
      guard window.string(kAXRoleAttribute) == kAXWindowRole,
        [kAXStandardWindowSubrole, kAXDialogSubrole].contains(
          window.string(kAXSubroleAttribute) ?? ""),
        window.bool("AXModal") != true, window.bool("AXFullScreen") != true
      else { continue }
      let id = inventory.id(of: window)
      guard id != 0 else { continue }
      byID[id] = window
      ids.append(id)
    }
    return ids
  }

  subscript(id: UInt32) -> AXUIElement? {
    byID[id]
  }
}
