import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

/// Window identity, Space membership, focus, and the on-screen inventory the
/// JavaScript side turns into Groups.
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

  /// Standard, movable, unminimized windows on exactly one Space, in
  /// WindowServer's front-to-back order. Hidden apps and this process are skipped.
  func onScreenWindows() -> [Snapshot.Window] {
    let descriptions =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0)
      as? [[String: Any]] ?? []
    var cache: [Int32: [AXUIElement]] = [:]
    return descriptions.compactMap { description in
      guard let pid = (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        pid != getpid(), let running = NSRunningApplication(processIdentifier: pid),
        !running.isHidden,
        (description[kCGWindowLayer as String] as? Int) == 0,
        let windowID = (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value
      else { return nil }
      if cache[pid] == nil {
        cache[pid] = AXUIElement.application(pid).elements(kAXWindowsAttribute)
      }
      guard let window = cache[pid]?.first(where: { id(of: $0) == windowID }),
        window.string(kAXSubroleAttribute) == kAXStandardWindowSubrole,
        window.bool(kAXMinimizedAttribute) != true,
        window.bool("AXFullScreen") != true,
        window.isSettable(kAXPositionAttribute), window.isSettable(kAXSizeAttribute),
        let frame = window.frame
      else { return nil }
      let membership = spaces(of: windowID)
      guard membership.count == 1 else { return nil }
      return Snapshot.Window(
        id: windowID, pid: pid, space: membership[0], frame: Frame(frame),
        title: window.string(kAXTitleAttribute) ?? "",
        app: running.localizedName ?? "", bundleID: running.bundleIdentifier ?? "")
    }
  }
}
