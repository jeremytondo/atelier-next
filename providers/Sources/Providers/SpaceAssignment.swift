import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum SpaceAssignmentOutcome: Equatable {
  case alreadyAssigned
  case privateAPI
  case privateAPIUnverified
  case dockMenu

  var message: String {
    switch self {
    case .alreadyAssigned:
      "All Desktops already active"
    case .privateAPI:
      "All Desktops assigned through the live WindowServer session"
    case .privateAPIUnverified:
      "WindowServer accepted All Desktops; only one ordinary Desktop is available, so membership cannot be cross-checked"
    case .dockMenu:
      "All Desktops assigned through the native Dock menu"
    }
  }
}

/// Puts a Quick App on every Desktop: session-level process assignment through
/// SkyLight first, then the user's own Dock menu as a persistent fallback. A
/// membership read across the required Desktops verifies either route.
struct SpaceAssignment {
  let api: PrivateAPI
  let poller: Poller

  func ensureAllDesktops(
    pid: pid_t, window: UInt32, target: TargetApplication, requiredSpaceIDs: Set<String>
  ) throws -> SpaceAssignmentOutcome {
    func verified() -> Bool {
      requiredSpaceIDs.isSubset(of: api.spaces(ofWindow: window))
    }
    // Membership in one Desktop cannot establish a sticky assignment.
    let verifiable = requiredSpaceIDs.count > 1
    if verifiable && verified() { return .alreadyAssigned }

    var privateFailure: String
    if let result = api.assignToAllSpaces(pid: pid) {
      if result == 0 {
        guard verifiable else { return .privateAPIUnverified }
        if poller.wait(0.8, until: verified) { return .privateAPI }
        privateFailure = "WindowServer accepted the assignment but membership was not verified"
      } else {
        privateFailure = "the private process-assignment function returned \(result)"
      }
    } else {
      privateFailure = "the private process-assignment function is unavailable"
    }

    do {
      try assignThroughDock(target: target)
    } catch let error as ProviderError {
      throw ProviderError(
        "Dock automation failed: \(error.message); private route also failed: \(privateFailure)")
    }
    guard !verifiable || poller.wait(1.2, until: verified) else {
      throw ProviderError(
        "macOS did not report the window on the required Desktops after either assignment route")
    }
    return .dockMenu
  }

  private func assignThroughDock(target: TargetApplication) throws {
    guard
      let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        .first
    else { throw ProviderError("Dock is not running") }
    let root = AXUIElement.application(dock.processIdentifier, timeout: 0.7)
    guard
      let item = root.descendants(maximumDepth: 5).first(where: { candidate in
        guard candidate.string(kAXRoleAttribute) == "AXDockItem" else { return false }
        if let url = candidate.attribute(kAXURLAttribute) as? URL {
          return url.standardizedFileURL == target.url.standardizedFileURL
        }
        if let string = candidate.string(kAXURLAttribute), let url = URL(string: string) {
          return url.standardizedFileURL == target.url.standardizedFileURL
        }
        return candidate.string(kAXTitleAttribute) == target.name
      })
    else { throw ProviderError("could not find \(target.name)'s Dock item") }
    guard item.perform(kAXShowMenuAction) else {
      throw ProviderError("could not open \(target.name)'s Dock menu")
    }

    let titles = dockMenuTitles()
    guard let options = waitForMenuItem(named: titles.options, in: root, timeout: 0.8) else {
      dismissMenu()
      throw ProviderError("the Options menu item was not exposed")
    }
    if waitForMenuItem(named: titles.allDesktops, in: root, timeout: 0.15) == nil {
      let action = options.actions.contains(kAXShowMenuAction) ? kAXShowMenuAction : kAXPressAction
      guard options.perform(action) else {
        dismissMenu()
        throw ProviderError("could not open the Options submenu")
      }
    }
    guard let allDesktops = waitForMenuItem(named: titles.allDesktops, in: root, timeout: 0.8),
      allDesktops.bool(kAXEnabledAttribute) == true
    else {
      dismissMenu()
      throw ProviderError(
        "the All Desktops item was unavailable; macOS only exposes it when multiple Desktops exist")
    }
    guard allDesktops.perform(kAXPressAction) else {
      dismissMenu()
      throw ProviderError("macOS rejected the All Desktops menu action")
    }
  }

  private func dockMenuTitles() -> (options: String, allDesktops: String) {
    guard let bundle = Bundle(path: "/System/Library/CoreServices/Dock.app") else {
      return ("Options", "All Desktops")
    }
    return (
      bundle.localizedString(forKey: "OPTIONS", value: "Options", table: "DockMenus"),
      bundle.localizedString(forKey: "ALL_DESKTOPS", value: "All Desktops", table: "DockMenus")
    )
  }

  private func waitForMenuItem(named title: String, in root: AXUIElement, timeout: TimeInterval)
    -> AXUIElement?
  {
    var item: AXUIElement?
    _ = poller.wait(timeout) {
      item = root.descendants(maximumDepth: 9).first {
        $0.string(kAXRoleAttribute) == kAXMenuItemRole && $0.string(kAXTitleAttribute) == title
      }
      return item != nil
    }
    return item
  }

  private func dismissMenu() {
    guard
      let down = CGEvent(
        keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: false)
    else { return }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }
}
