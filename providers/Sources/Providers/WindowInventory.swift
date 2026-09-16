import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

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

  /// Every ordinary-layer window WindowServer knows, on any Space, minimized or
  /// hidden, in front-to-back order; this process is skipped. Nil when the
  /// window server refuses the census, which is not evidence of anything. `ordinary` is
  /// Accessibility's verdict on the window and is nil when Accessibility did
  /// not list it, which happens on inactive Desktops. Subroles are not trusted:
  /// a hidden or minimized document window reports AXDialog and an Open panel
  /// reports AXStandardWindow, while a minimizable AXWindow is ordinary in
  /// every state.
  func allWindows() -> [Snapshot.Window]? {
    guard
      let descriptions =
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0) as? [[String: Any]]
    else { return nil }
    var cache: [Int32: [UInt32: AXUIElement]] = [:]
    return descriptions.compactMap { description in
      guard let pid = (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        pid != getpid(), let running = NSRunningApplication(processIdentifier: pid),
        (description[kCGWindowLayer as String] as? Int) == 0,
        let windowID = (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value
      else { return nil }
      if cache[pid] == nil {
        var byID: [UInt32: AXUIElement] = [:]
        for element in AXUIElement.application(pid).elements(kAXWindowsAttribute) {
          byID[id(of: element)] = element
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
