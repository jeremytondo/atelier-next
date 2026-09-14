// The pinned HS2 API only exposes activating launch. This transaction keeps
// launch/reopen, placement, All Desktops assignment, and final focus together so
// summoning an app cannot switch away before its membership has been established.
// General Group focus, Fill, shortcuts, and observation live in HS2 JavaScript.
import CoreGraphics
import Darwin
import Foundation
import SpaceControlCore

struct RunningApp: Equatable {
  let pid: pid_t
  let bundleID: String?
}

/// The AppKit, Accessibility, and SkyLight behavior a toggle drives. Apps are
/// process IDs and windows are CGWindowIDs so fakes need no AppKit objects.
struct QuickAppSeams {
  var topology: () -> [DisplaySpaceSnapshot]
  var targetDisplay: ([DisplaySpaceSnapshot]) -> TargetDisplay?
  var resolve: (String) throws -> TargetApplication
  /// The first running instance of a bundle identifier.
  var running: (String) -> pid_t?
  var frontmost: () -> RunningApp?
  var isRunning: (pid_t) -> Bool
  var isHidden: (pid_t) -> Bool
  var hide: (pid_t) -> Bool
  var unhide: (pid_t) -> Void
  /// Launches or reopens without activating and returns once macOS reports the process.
  var launch: (TargetApplication) throws -> pid_t
  /// Standard and dialog windows that are neither modal nor full screen.
  var windows: (pid_t) -> [UInt32]
  var isMinimized: (UInt32) -> Bool
  var unminimize: (UInt32) -> Bool
  var frame: (UInt32) -> CGRect?
  var move: (UInt32, CGPoint) -> Bool
  var resize: (UInt32, CGSize) -> Bool
  /// Makes the window main, activates its app, and raises it.
  var focus: (pid_t, UInt32) -> Void
  var focusedWindow: () -> UInt32
  var spaces: (UInt32) -> [String]
  /// The display's frame minus the menu bar and Dock, in top-left coordinates.
  var visibleFrame: (CGDirectDisplayID) -> CGRect?
  /// Puts the window on every required Desktop and describes how.
  var assignToAllDesktops: (pid_t, UInt32, TargetApplication, Set<String>) throws -> String
  var poller: Poller
}

struct QuickAppState {
  var pid: pid_t
  var window: UInt32
  /// The app to return to when the Quick App hides, unless it was the Quick App itself.
  var previous: RunningApp?
  var previousWindow: UInt32
  var display: String
  var space: String
}

/// One toggle per configured app: hide it when it is frontmost with a visible
/// window, otherwise summon it to the center of the target display.
final class QuickApps {
  static let windowTimeout: TimeInterval = 4
  static let placementAttempts = 20
  private let seams: QuickAppSeams
  private(set) var states: [String: QuickAppState] = [:]

  init(seams: QuickAppSeams) {
    self.seams = seams
  }

  func toggle(_ request: QuickToggleRequest) throws -> QuickToggleResponse {
    let target = try seams.resolve(request.app)
    if let expected = request.expectedBundleID, expected != target.bundleIdentifier {
      throw EngineError(
        "The configured app identity changed. Review its app reference in init.js and reload.")
    }
    if let size = request.size {
      guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
        throw EngineError("Invalid quick app size")
      }
    }
    let running = seams.running(target.bundleIdentifier)
    if let pid = running, !seams.isHidden(pid), seams.frontmost()?.pid == pid,
      seams.windows(pid).contains(where: { !seams.isMinimized($0) })
    {
      return try hide(pid: pid, target: target)
    }
    return try summon(running: running, target: target, size: request.size)
  }

  private func hide(pid: pid_t, target: TargetApplication) throws -> QuickToggleResponse {
    let bundleID = target.bundleIdentifier
    guard seams.hide(pid) else { throw EngineError("Could not hide \(target.name)") }
    guard seams.poller.wait(1, until: { seams.isHidden(pid) }) else {
      throw EngineError("Could not verify quick app was hidden")
    }
    var restored = false
    if let state = states[bundleID], state.pid == pid, let previous = state.previous,
      seams.isRunning(previous.pid), currentSpace(on: state.display) == state.space,
      seams.spaces(state.previousWindow).contains(state.space),
      seams.windows(previous.pid).contains(state.previousWindow),
      !seams.isMinimized(state.previousWindow)
    {
      seams.focus(previous.pid, state.previousWindow)
      restored = seams.poller.wait(1, until: { seams.focusedWindow() == state.previousWindow })
    }
    states[bundleID]?.previous = nil
    return QuickToggleResponse(action: .hidden, bundleID: bundleID, restoredFocus: restored)
  }

  private func summon(running: pid_t?, target: TargetApplication, size: QuickAppSize?) throws
    -> QuickToggleResponse
  {
    let bundleID = target.bundleIdentifier
    let topology = seams.topology()
    guard let display = seams.targetDisplay(topology),
      let desktop = topology.first(where: { $0.identifier == display.topologyIdentifier }),
      desktop.regularDesktops.contains(where: { $0.id == desktop.currentSpaceID })
    else {
      throw EngineError(
        "Quick apps require an ordinary Desktop; fullscreen and Split View are unsupported")
    }
    let space = String(desktop.currentSpaceID)
    let frontmost = seams.frontmost()
    let remembered = states[bundleID]
    // A repeated press while the Quick App is already frontmost keeps the app
    // the user came from, so hiding later still returns there.
    let reusePrevious =
      frontmost?.bundleID == bundleID && remembered?.display == display.topologyIdentifier
      && remembered?.space == space
    let previous = reusePrevious ? remembered?.previous : frontmost
    let previousWindow = reusePrevious ? (remembered?.previousWindow ?? 0) : seams.focusedWindow()
    func checkDesktop() throws {
      guard currentSpace(on: display.topologyIdentifier) == space else {
        throw EngineError("Active Desktop changed during quick app summon")
      }
    }

    let pid: pid_t
    if let running, !seams.windows(running).isEmpty {
      pid = running
    } else {
      pid = try seams.launch(target)
    }
    var selected: UInt32?
    _ = seams.poller.wait(Self.windowTimeout) {
      let windows = seams.windows(pid)
      let focused = seams.focusedWindow()
      selected =
        windows.first { remembered?.pid == pid && $0 == remembered?.window }
        ?? windows.first { $0 == focused } ?? windows.first
      return selected != nil
    }
    guard let window = selected else {
      throw EngineError(
        "\(target.name) did not expose a standard window; close fullscreen mode or open its main window"
      )
    }
    try checkDesktop()
    // Hidden apps may have no queryable Space membership. Unhide without activating
    // before assignment; only focus after membership on the captured Desktop is verified.
    seams.unhide(pid)
    if seams.isMinimized(window) {
      guard seams.unminimize(window) else {
        throw EngineError("Quick app window could not be unminimized")
      }
    }
    try place(window, on: display.displayID, size: size)
    try checkDesktop()
    let expected = Set(desktop.regularDesktops.map { String($0.id) })
    let assignment = try seams.assignToAllDesktops(pid, window, target, expected)
    try checkDesktop()
    // Keep this identity even if a later step fails, allowing a second press to hide.
    states[bundleID] = QuickAppState(
      pid: pid, window: window,
      previous: previous?.bundleID == bundleID ? nil : previous,
      previousWindow: previousWindow,
      display: display.topologyIdentifier, space: space)
    guard seams.poller.wait(1, until: { expected.isSubset(of: seams.spaces(window)) }) else {
      throw EngineError("Quick app is not available on every Desktop of the captured display")
    }
    seams.focus(pid, window)
    let focused = seams.poller.wait(1.5, until: { seams.focusedWindow() == window })
    try checkDesktop()
    guard focused else { throw EngineError("Could not focus the quick app window") }
    return QuickToggleResponse(
      action: .shown, bundleID: bundleID, window: window,
      display: display.topologyIdentifier, space: space,
      frame: seams.frame(window).map(Frame.init), assignment: assignment)
  }

  /// Centers the window in the display's usable area, shrinking it to fit.
  private func place(_ window: UInt32, on displayID: CGDirectDisplayID, size: QuickAppSize?)
    throws
  {
    guard let usable = seams.visibleFrame(displayID)?.insetBy(dx: 8, dy: 8) else {
      throw EngineError("Quick app display disconnected")
    }
    guard let old = seams.frame(window) else {
      throw EngineError("Quick app window has no readable frame")
    }
    func center(_ size: CGSize) -> CGPoint {
      CGPoint(x: usable.midX - size.width / 2, y: usable.midY - size.height / 2)
    }
    // Move without activation so the window reaches the captured display first.
    guard
      seams.move(
        window,
        center(
          CGSize(width: min(old.width, usable.width), height: min(old.height, usable.height))))
    else { throw EngineError("Quick app refused window placement") }
    if size != nil || old.width > usable.width || old.height > usable.height {
      let requested = CGSize(
        width: min(size?.width ?? old.width, usable.width),
        height: min(size?.height ?? old.height, usable.height))
      guard seams.resize(window, requested) else {
        throw EngineError("Quick app refused the requested size")
      }
    }
    // Recenter using the actual size: apps may impose their own minimum dimensions.
    for _ in 0..<Self.placementAttempts {
      seams.poller.pause()
      guard let actual = seams.frame(window) else { continue }
      let point = center(actual.size)
      guard seams.move(window, point) else {
        throw EngineError("Quick app refused window placement")
      }
      seams.poller.pause()
      if let settled = seams.frame(window),
        abs(settled.minX - point.x) < 3, abs(settled.minY - point.y) < 3,
        abs(settled.width - actual.width) < 3, abs(settled.height - actual.height) < 3
      {
        return
      }
    }
    throw EngineError("Quick app did not settle at the center of the captured display")
  }

  private func currentSpace(on displayIdentifier: String) -> String? {
    seams.topology().first { $0.identifier == displayIdentifier }.map { String($0.currentSpaceID) }
  }
}
