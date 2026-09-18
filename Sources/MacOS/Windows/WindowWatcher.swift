import AppKit
import ApplicationServices

/// Notices that windows, focus, or Spaces may have changed: the workspace says
/// when apps and Spaces come and go, and an Accessibility observer on each
/// app says when its windows do. Observers live on one thread of their own,
/// because adding one waits on the app, and a frozen app must hold up nothing
/// else. Everything here only yields a hint; nobody is told what changed.
final class WindowWatcher: NSObject, @unchecked Sendable {
  private static let notifications = [
    kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
    kAXMainWindowChangedNotification, kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification, kAXApplicationHiddenNotification,
    kAXApplicationShownNotification, kAXTitleChangedNotification,
    kAXUIElementDestroyedNotification,
  ]

  private let hint: AsyncStream<Void>.Continuation
  /// Touched only on `thread`.
  private var observers: [pid_t: AXObserver] = [:]
  private var thread: Thread!
  private var runLoop: CFRunLoop!

  /// The stream ends only with the process; one watcher serves the whole app.
  static func changes() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self, bufferingPolicy: .bufferingNewest(1))
    WindowWatcher(hint: continuation).start()
    return stream
  }

  private init(hint: AsyncStream<Void>.Continuation) {
    self.hint = hint
  }

  private func start() {
    let ready = DispatchSemaphore(value: 0)
    thread = Thread { [self] in
      runLoop = CFRunLoopGetCurrent()
      // A run loop with nothing to wait on returns at once.
      RunLoop.current.add(Port(), forMode: .default)
      ready.signal()
      CFRunLoopRun()
    }
    thread.name = "com.elevenideas.Atelier.watcher"
    thread.start()
    ready.wait()

    let workspace = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
    ] {
      workspace.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
    }
    // Background processes have no windows of their own to watch.
    let running = NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy != .prohibited }.map(\.processIdentifier)
    onThread { [self] in running.forEach(observe) }
  }

  @objc private func workspaceChanged(_ notification: Notification) {
    hint.yield()
    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    guard let pid = app?.processIdentifier else { return }
    let isGone = notification.name == NSWorkspace.didTerminateApplicationNotification
    // An app that was not ready for an observer at launch is by activation.
    onThread { [self] in isGone ? forget(pid) : observe(pid) }
  }

  private func onThread(_ work: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
    CFRunLoopWakeUp(runLoop)
  }

  private func observe(_ pid: pid_t) {
    guard observers[pid] == nil, pid != getpid() else { return }
    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, _, watcher in
      guard let watcher else { return }
      Unmanaged<WindowWatcher>.fromOpaque(watcher).takeUnretainedValue().hint.yield()
    }
    guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else {
      return
    }
    let app = AXUIElementCreateApplication(pid)
    let watcher = Unmanaged.passUnretained(self).toOpaque()
    // An app that cannot take the first is not asked for the rest: each
    // refusal can cost a full time limit. It gets another chance when activated.
    for (index, notification) in Self.notifications.enumerated() {
      let added = AXObserverAddNotification(observer, app, notification as CFString, watcher)
      guard added == .success || index > 0 else { return }
    }
    CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
    observers[pid] = observer
  }

  private func forget(_ pid: pid_t) {
    guard let observer = observers.removeValue(forKey: pid) else { return }
    CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
  }
}
