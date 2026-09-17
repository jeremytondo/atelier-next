import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import SpaceControlCore

/// Window identity, Space membership, focus, and the census of application
/// windows the JavaScript side turns into per-Desktop lists.
struct WindowInventory {
  let api: PrivateAPI

  func id(of element: AXUIElement) -> UInt32 {
    api.windowID(of: element)
  }

  func spaces(of id: UInt32) -> [String] {
    api.spaces(ofWindow: id)
  }

  func focusedWindowID() -> UInt32 {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let focused = AXUIElement.application(pid).element(kAXFocusedWindowAttribute)
    else { return 0 }
    return id(of: focused)
  }

  /// Ordinary-layer windows on any Space, minimized or hidden, in front-to-back
  /// order; this process is skipped. WindowServer can retain closed NSWindows,
  /// so a successful AXWindows read also removes offscreen entries missing from
  /// an active Space. Inactive Spaces and failed AX reads prove nothing.
  /// Nil when WindowServer refuses the census. `ordinary` is
  /// Accessibility's verdict on the window and is nil when Accessibility did
  /// not list it, which happens on inactive Desktops. Subroles are not trusted:
  /// a hidden or minimized document window reports AXDialog and an Open panel
  /// reports AXStandardWindow, while a minimizable AXWindow is ordinary in
  /// every state.
  func allWindows() -> [Snapshot.Window]? {
    let before = activeSpaces()
    guard
      let descriptions =
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0) as? [[String: Any]]
    else { return nil }
    var cache: [Int32: [UInt32: AXUIElement]] = [:]
    var accessible: [Int32: Set<UInt32>] = [:]
    let census: [Snapshot.Window] = descriptions.compactMap { description in
      guard let pid = (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        pid != getpid(), let running = NSRunningApplication(processIdentifier: pid),
        (description[kCGWindowLayer as String] as? Int) == 0,
        let windowID = (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value
      else { return nil }
      if cache[pid] == nil {
        var byID: [UInt32: AXUIElement] = [:]
        // An empty successful read differs from a timeout. A failed window-ID
        // lookup also makes the application's enumeration inconclusive.
        if let elements = AXUIElement.application(pid).attribute(kAXWindowsAttribute)
          as? [AXUIElement]
        {
          for element in elements { byID[id(of: element)] = element }
          if byID[0] == nil { accessible[pid] = Set(byID.keys) }
        }
        cache[pid] = byID
      }
      let window = cache[pid]?[windowID]
      return Snapshot.Window(
        id: windowID, pid: pid, launched: running.launchDate?.timeIntervalSince1970 ?? 0,
        app: running.localizedName ?? "", bundleID: running.bundleIdentifier ?? "",
        title: window?.string(kAXTitleAttribute) ?? "",
        spaces: spaces(of: windowID),
        onScreen: description[kCGWindowIsOnscreen as String] as? Bool == true,
        ordinary: window.map { $0.isOrdinary })
    }
    // A Desktop switch while AX replies were arriving cannot prove closure.
    let after = activeSpaces()
    return Self.excludingClosed(
      census, accessible: accessible, activeSpaces: before == after ? before : [])
  }

  private func activeSpaces() -> Set<String> {
    Set(SpaceTopology.decode(api.managedDisplaySpaces()).map { String($0.currentSpaceID) })
  }

  /// Reconciles WindowServer's retained objects with successful AX enumerations.
  /// A hidden/minimized window is still in AXWindows; an inactive one may not be.
  static func excludingClosed(
    _ census: [Snapshot.Window], accessible: [Int32: Set<UInt32>], activeSpaces: Set<String>
  ) -> [Snapshot.Window] {
    census.filter { window in
      guard !window.onScreen, !activeSpaces.isDisjoint(with: window.spaces),
        let ids = accessible[window.pid]
      else { return true }
      return ids.contains(window.id)
    }
  }
}

extension AXUIElement {
  /// An application window that can be minimized: a document or main window
  /// rather than a dialog, panel, or sheet, whatever subrole it reports today.
  var isOrdinary: Bool {
    string(kAXRoleAttribute) == kAXWindowRole && isSettable(kAXMinimizedAttribute)
      && bool("AXFullScreen") != true
  }
}
