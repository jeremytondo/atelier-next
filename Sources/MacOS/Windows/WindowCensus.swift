import ApplicationServices
import CoreGraphics
import Foundation

/// The census of windows: WindowServer says which exist, where, and in what
/// order; each app's Accessibility says which are ordinary and what they are
/// called. Apps are asked side by side in the background, each within a time
/// limit, so a frozen app delays the census by one limit and its windows
/// simply go unconfirmed.
struct WindowCensus: Sendable {
  let skyLight: SkyLight

  /// Each request to an app gives up after this many seconds.
  static let requestTimeLimit: Float = 0.25

  /// How long one app may take to describe all its windows.
  static let appTimeLimit: TimeInterval = 0.5

  private static let queue = DispatchQueue(
    label: "com.elevenideas.Atelier.census", qos: .userInitiated, attributes: .concurrent)

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
  }

  func focus(of app: pid_t?) async -> Focus {
    await Self.background {
      let window = app.flatMap {
        AXUIElementCreateApplication($0).element(kAXFocusedWindowAttribute)
      }.flatMap(skyLight.windowID)
      return Focus(
        window: window, windowSpaces: window.map(skyLight.spaces) ?? [],
        activeSpace: skyLight.activeSpace())
    }
  }

  func snapshot() async -> Snapshot? {
    guard let listed = await Self.background({ listWindows() }) else { return nil }
    let answers = await withTaskGroup(of: (pid_t, AppWindows).self) { group in
      for pid in Set(listed.map(\.pid)) {
        group.addTask { (pid, await Self.background { read(pid) }) }
      }
      return await group.reduce(into: [pid_t: AppWindows]()) { $0[$1.0] = $1.1 }
    }
    return Snapshot(
      // Read last, so the Spaces are as fresh as the slowest app's answer.
      displays: DisplaySpaces.decode(skyLight.managedDisplaySpaces()),
      windows: listed.map { window in
        WindowFacts(
          id: window.id, app: window.app, title: answers[window.pid]?.titles[window.id] ?? "",
          spaces: window.spaces, isOnScreen: window.isOnScreen,
          isOrdinary: answers[window.pid]?.ordinary.contains(window.id) == true)
      })
  }

  /// Layer-0 windows on any Space, minimized or hidden, front to back. This
  /// process is skipped. WindowServer can keep closed windows listed; they
  /// never come back as ordinary because their app no longer reports them.
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

  /// Subroles are not trusted: a hidden or minimized document window reports
  /// AXDialog and an Open panel reports AXStandardWindow. A window that can be
  /// minimized is ordinary in every state.
  private func read(_ pid: pid_t) -> AppWindows {
    let deadline = Date(timeIntervalSinceNow: Self.appTimeLimit)
    let app = AXUIElementCreateApplication(pid)
    var result = AppWindows()
    guard let windows = app.attribute(kAXWindowsAttribute) as? [AXUIElement] else { return result }
    for window in windows where Date() < deadline {
      guard let id = skyLight.windowID(of: window),
        let values = window.attributes([kAXRoleAttribute, kAXTitleAttribute, "AXFullScreen"])
      else { continue }
      result.titles[id] = values[1] as? String
      if values[0] as? String == kAXWindowRole, values[2] as? Bool != true,
        window.isSettable(kAXMinimizedAttribute)
      {
        result.ordinary.insert(id)
      }
    }
    return result
  }

  /// Accessibility requests block their thread, so they stay off both the main
  /// thread and Swift's small cooperative pool.
  private static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: work()) }
    }
  }
}
