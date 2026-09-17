import AppKit
import ApplicationServices
import CoreGraphics

/// The census of windows: WindowServer says which exist, where, and in what
/// order; each app's Accessibility says which are ordinary and what they are
/// called. Apps are asked side by side in the background, each within a time
/// limit, so a frozen app delays the census by one limit and its windows
/// simply go unanswered.
struct WindowCensus: Sendable {
  let skyLight: SkyLight

  /// Each request to an app gives up after this many seconds.
  static let requestTimeLimit: Float = 0.25

  /// How long one app may take to describe all its windows.
  static let appTimeLimit: TimeInterval = 0.5

  private struct ListedWindow: Sendable {
    var id: UInt32
    var pid: pid_t
    var app: String
    var isOnScreen: Bool
    var spaces: [UInt64]
  }

  private struct AppWindows: Sendable {
    var titles: [UInt32: String] = [:]
    var ordinary: Set<UInt32> = []
    /// True when the app listed its windows and every one could be read.
    var isComplete = false
    var launched: Double?
  }

  func focus(of app: pid_t?) async -> Focus {
    await Background.run {
      let element = app.flatMap {
        AXUIElementCreateApplication($0).element(kAXFocusedWindowAttribute)
      }
      let window = element.flatMap(skyLight.windowID)
      return Focus(
        app: app, window: window, windowIsOrdinary: window != nil && element?.isOrdinary == true,
        windowSpaces: window.map(skyLight.spaces) ?? [], activeSpace: skyLight.activeSpace())
    }
  }

  func snapshot() async -> Snapshot? {
    let shownBefore = shownSpaces()
    guard let listed = await Background.run({ listWindows() }) else { return nil }
    let answers = await withTaskGroup(of: (pid_t, AppWindows).self) { group in
      for pid in Set(listed.map(\.pid)) {
        group.addTask { (pid, await Background.run { read(pid) }) }
      }
      return await group.reduce(into: [pid_t: AppWindows]()) { $0[$1.0] = $1.1 }
    }
    // Read last, so the Spaces are as fresh as the slowest app's answer.
    let displays = DisplaySpaces.decode(skyLight.managedDisplaySpaces())
    // Apps list only windows on the Spaces being shown. After a switch
    // part-way, a window left out may have been on the other side of it.
    let isSettled = shownBefore == Set(displays.map(\.currentSpace))
    return Snapshot(
      displays: displays,
      windows: listed.map { window in
        let answer = answers[window.pid]
        let report: WindowFacts.Report =
          if answer?.ordinary.contains(window.id) == true {
            .ordinary
          } else if answer?.titles[window.id] != nil {
            .other
          } else if answer?.isComplete == true, isSettled {
            .missing
          } else {
            .unanswered
          }
        return WindowFacts(
          id: window.id, app: window.pid, appLaunched: answer?.launched, appName: window.app,
          title: answer?.titles[window.id] ?? "", spaces: window.spaces,
          isOnScreen: window.isOnScreen, report: report)
      })
  }

  private func shownSpaces() -> Set<UInt64> {
    Set(DisplaySpaces.decode(skyLight.managedDisplaySpaces()).map(\.currentSpace))
  }

  /// Layer-0 windows on any Space, minimized or hidden, front to back. This
  /// process is skipped.
  private func listWindows() -> [ListedWindow]? {
    guard
      let descriptions =
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0) as? [[String: Any]]
    else { return nil }
    return descriptions.compactMap { description in
      guard (description[kCGWindowLayer as String] as? Int) == 0,
        let pid = (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        pid != getpid(),
        let id = (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value
      else { return nil }
      return ListedWindow(
        id: id, pid: pid, app: description[kCGWindowOwnerName as String] as? String ?? "",
        isOnScreen: description[kCGWindowIsOnscreen as String] as? Bool == true,
        spaces: skyLight.spaces(ofWindow: id))
    }
  }

  private func read(_ pid: pid_t) -> AppWindows {
    let deadline = Date(timeIntervalSinceNow: Self.appTimeLimit)
    var result = AppWindows()
    result.launched =
      NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970
    guard
      let windows = AXUIElementCreateApplication(pid).attribute(kAXWindowsAttribute)
        as? [AXUIElement]
    else { return result }
    var isComplete = true
    for window in windows {
      guard Date() < deadline, let id = skyLight.windowID(of: window),
        let values = window.attributes([kAXRoleAttribute, kAXTitleAttribute, "AXFullScreen"])
      else {
        isComplete = false
        continue
      }
      result.titles[id] = values[1] as? String ?? ""
      if Self.isOrdinary(role: values[0], isFullScreen: values[2], window: window) {
        result.ordinary.insert(id)
      }
    }
    result.isComplete = isComplete
    return result
  }

  /// Subroles are not trusted: a hidden or minimized document window reports
  /// AXDialog and an Open panel reports AXStandardWindow. A window that can be
  /// minimized is ordinary in every state.
  fileprivate static func isOrdinary(
    role: CFTypeRef?, isFullScreen: CFTypeRef?, window: AXUIElement
  ) -> Bool {
    role as? String == kAXWindowRole && isFullScreen as? Bool != true
      && window.isSettable(kAXMinimizedAttribute)
  }
}

extension AXUIElement {
  fileprivate var isOrdinary: Bool {
    guard let values = attributes([kAXRoleAttribute, "AXFullScreen"]) else { return false }
    return WindowCensus.isOrdinary(role: values[0], isFullScreen: values[1], window: self)
  }
}

enum Background {
  private static let queue = DispatchQueue(
    label: "com.elevenideas.Atelier.background", qos: .userInitiated, attributes: .concurrent)

  /// Accessibility requests block their thread, so they stay off both the main
  /// thread and Swift's small cooperative pool.
  static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: work()) }
    }
  }
}
