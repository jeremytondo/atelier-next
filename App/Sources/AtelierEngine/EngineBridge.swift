import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import DesktopBridge
import Foundation
import SpaceControlCore

/// Native mechanisms only: no hotkeys, group policy, or persistent preferences.
@MainActor
final class EngineBridge {
  let runtime: SpaceRuntime
  private lazy var missionControl = MissionControlAccessibility(runtime: runtime)
  let resolver = TargetDisplayResolver()
  private typealias Connection = @convention(c) () -> Int32
  private typealias Membership = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
  private typealias WindowID =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
  private let sky: UnsafeMutableRawPointer
  private let ax: UnsafeMutableRawPointer
  private let connection: Int32
  private let membership: Membership
  private let windowID: WindowID

  let quickAssignment = SpaceAssignmentCoordinator()
  var quickStates: [String: QuickAppState] = [:]

  /// Every command the helper answers. Adding one means one entry here and one
  /// typed request/response pair in HelperProtocol.swift.
  private lazy var commands: [String: HelperProtocol.Handler] = [
    "hello": HelperProtocol.handler { (_: NoArguments) in
      HelloResponse(protocolVersion: HelperProtocol.version, trusted: AXIsProcessTrusted())
    },
    "snapshot": HelperProtocol.handler { (_: NoArguments) in self.snapshot() },
    "quickResolve": HelperProtocol.handler { (request: ApplicationRequest) in
      let target = try TargetApplication.resolve(request.app)
      return ApplicationResponse(bundleID: target.bundleIdentifier, name: target.name)
    },
    "membership": HelperProtocol.handler { (request: MembershipRequest) in
      MembershipResponse(spaces: self.spaces(request.window), focused: self.focusedID())
    },
    "switch": trusted { (request: SpaceRequest) in try self.switchDesktop(request) },
    "create": trusted { (request: SpaceRequest) in try self.createDesktop(request) },
    "reorder": trusted { (request: SpaceRequest) in try self.reorderDesktop(request) },
    "delete": trusted { (request: SpaceRequest) in try self.deleteDesktop(request) },
    "quickToggle": trusted { (request: QuickToggleRequest) in try self.toggleQuickApp(request) },
  ]

  init() throws {
    runtime = try SpaceRuntime()
    guard
      let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
      let ax = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
      let c = dlsym(sky, "SLSMainConnectionID"),
      let m = dlsym(sky, "SLSCopySpacesForWindows"),
      let w = dlsym(ax, "_AXUIElementGetWindow")
    else {
      throw EngineError("Required native window identity/Space symbols unavailable")
    }
    self.sky = sky
    self.ax = ax
    connection = unsafeBitCast(c, to: Connection.self)()
    membership = unsafeBitCast(m, to: Membership.self)
    windowID = unsafeBitCast(w, to: WindowID.self)
  }

  func cleanup() {
    runtime.restoreTemporarilyEnabledHotKeys()
    missionControl.resetKeyboardNavigation()
  }

  func handle(_ line: String) -> String {
    HelperProtocol.respond(to: line, using: commands)
  }

  private func trusted<Request: Decodable>(
    _ body: @escaping (Request) throws -> any Encodable
  ) -> HelperProtocol.Handler {
    HelperProtocol.handler { (request: Request) in
      guard AXIsProcessTrusted() else {
        throw EngineError("Accessibility permission required for the helper's responsible app")
      }
      return try body(request)
    }
  }

  func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  func id(_ element: AXUIElement) -> UInt32 {
    var result: UInt32 = 0
    return windowID(element, &result) == .success ? result : 0
  }

  func spaces(_ id: UInt32) -> [String] {
    let value = membership(connection, 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue()
    return (value as? [NSNumber] ?? []).map { $0.stringValue }
  }

  func element(pid: Int32, window: UInt32) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.35)
    return (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first { id($0) == window }
  }

  func focusedID() -> UInt32 {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let focused = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
      CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return 0 }
    return id(unsafeDowncast(focused, to: AXUIElement.self))
  }

  func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
      let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &point),
      AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size)
    else { return nil }
    return CGRect(origin: point, size: size)
  }

  private func inventory() -> [Snapshot.Window] {
    let descriptions =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0)
      as? [[String: Any]] ?? []
    var cache: [Int32: [AXUIElement]] = [:]
    return descriptions.compactMap { d in
      guard let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        pid != getpid(), let running = NSRunningApplication(processIdentifier: pid),
        !running.isHidden,
        (d[kCGWindowLayer as String] as? Int) == 0,
        let wid = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value
      else { return nil }
      if cache[pid] == nil {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        cache[pid] = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
      }
      guard let window = cache[pid]?.first(where: { id($0) == wid }),
        attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
        attribute(window, kAXMinimizedAttribute) as? Bool != true,
        attribute(window, "AXFullScreen") as? Bool != true
      else { return nil }
      var position = DarwinBoolean(false)
      var size = DarwinBoolean(false)
      AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &position)
      AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &size)
      let membership = spaces(wid)
      guard position.boolValue, size.boolValue, membership.count == 1, let rect = frame(window)
      else { return nil }
      return Snapshot.Window(
        id: wid, pid: pid, space: membership[0], frame: Frame(rect),
        title: attribute(window, kAXTitleAttribute) as? String ?? "",
        app: running.localizedName ?? "", bundleID: running.bundleIdentifier ?? "")
    }
  }

  private func snapshot() -> Snapshot {
    let topology = runtime.snapshot()
    let target = resolver.resolve(in: topology)
    let trusted = AXIsProcessTrusted()
    return Snapshot(
      trusted: trusted, focused: focusedID(),
      targetDisplay: target?.topologyIdentifier ?? "",
      missionControl: missionControl.isVisible(),
      displays: topology.map { display in
        Snapshot.Display(
          id: display.identifier, current: String(display.currentSpaceID),
          spaces: display.spaces.map {
            Snapshot.Space(id: String($0.id), fullscreen: $0.isFullscreen)
          })
      },
      windows: trusted ? inventory() : [])
  }

  private func creationSeams() -> DesktopCreationSeams {
    DesktopCreationSeams(
      topology: { self.runtime.snapshot() },
      missionControlVisible: { self.missionControl.isVisible() },
      dockCount: { DesktopBridge.dockDesktopCount()?.intValue },
      create: {
        let report = DesktopBridge.createDesktop()
        if let id = (report["createdID"] as? NSNumber)?.uint64Value { return .created(id) }
        let reason = report["error"] as? String ?? "Desktop creation failed"
        return report["dispatched"] as? Bool == true ? .uncertain(reason) : .refused(reason)
      },
      enterDesktop: { number in self.runtime.postSymbolicHotKey(UInt32(117 + number)) },
      now: { ProcessInfo.processInfo.systemUptime },
      pause: { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) })
  }

  func wait(_ timeout: Double = 3, until condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    repeat {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    } while Date() < end
    return condition()
  }

  /// The display and Desktop a Space operation acts on, refusing when either
  /// moved since the JS side observed them.
  private func spaceTarget(_ request: SpaceRequest) throws -> (
    TargetDisplay, DisplaySpaceSnapshot, [DisplaySpaceSnapshot]
  ) {
    let before = runtime.snapshot()
    guard let target = resolver.resolve(in: before),
      let display = before.first(where: { $0.identifier == target.topologyIdentifier })
    else { throw EngineError("No target display") }
    if let expected = request.display, expected != target.topologyIdentifier {
      throw EngineError("Target display changed before operation")
    }
    if let expected = request.current, expected != String(display.currentSpaceID) {
      throw EngineError("Active Space changed before operation")
    }
    return (target, display, before)
  }

  private func switchDesktop(_ request: SpaceRequest) throws -> any Encodable {
    let (target, display, before) = try spaceTarget(request)
    guard let number = request.number else { throw EngineError("number required") }
    guard
      let desktop = SpaceTopology.desktop(
        number: number, on: target.topologyIdentifier, displays: before)
    else { return NoopResponse() }
    if desktop.id != display.currentSpaceID {
      let restoreDeadline = Date().addingTimeInterval(0.27)
      guard let global = SpaceTopology.globalDesktopNumber(for: desktop.id, displays: before),
        global <= 16,
        runtime.postSymbolicHotKey(UInt32(117 + global))
      else { throw EngineError("Native Desktop shortcut unavailable") }
      guard
        wait(until: {
          runtime.snapshot().first(where: { $0.identifier == target.topologyIdentifier })?
            .currentSpaceID == desktop.id
        })
      else { throw EngineError("Native shortcut sent but destination was not verified") }
      if Date() < restoreDeadline { RunLoop.current.run(until: restoreDeadline) }
    }
    // Restore temporary symbolic registrations before the app reenables its bindings.
    runtime.restoreTemporarilyEnabledHotKeys()
    return snapshot()
  }

  private func createDesktop(_ request: SpaceRequest) throws -> Snapshot {
    let (target, _, _) = try spaceTarget(request)
    defer { cleanup() }
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
      throw EngineError("Desktop creation requires macOS 27")
    }
    if let reason = DesktopBridge.unavailableReason() { throw EngineError(reason) }
    let created = try DesktopCreation.createAndEnter(
      on: target.topologyIdentifier, seams: creationSeams())
    var result = snapshot()
    result.created = String(created)
    return result
  }

  private func reorderDesktop(_ request: SpaceRequest) throws -> Snapshot {
    let (target, _, before) = try spaceTarget(request)
    guard let offset = request.offset, abs(offset) == 1 else {
      throw EngineError("offset must be -1 or 1")
    }
    defer { cleanup() }
    try openMissionControl(on: target, topology: before)
    _ = try missionControl.reorderActiveDesktop(
      offset: offset, on: target, topology: runtime.snapshot()
    ).get()
    _ = try missionControl.enterActiveDesktop(on: target, topology: runtime.snapshot()).get()
    return snapshot()
  }

  private func deleteDesktop(_ request: SpaceRequest) throws -> Snapshot {
    let (target, display, before) = try spaceTarget(request)
    guard display.regularDesktops.count > 1 else {
      throw EngineError("The final Desktop cannot be deleted")
    }
    let departing = inventory().filter { $0.space == String(display.currentSpaceID) }.map(\.id)
    defer { cleanup() }
    try openMissionControl(on: target, topology: before)
    _ = try missionControl.deleteActiveDesktop(on: target, topology: runtime.snapshot()).get()
    _ = try missionControl.enterActiveDesktop(on: target, topology: runtime.snapshot()).get()
    var result = snapshot()
    guard
      wait(until: {
        departing.allSatisfy { window in
          let memberships = spaces(window)
          return !memberships.isEmpty && !memberships.contains(String(display.currentSpaceID))
        }
      })
    else {
      throw EngineError(
        "Desktop deleted, but could not verify all eligible windows survived on another Space")
    }
    result.migratedWindows = departing.map { Snapshot.WindowSpaces(id: $0, spaces: spaces($0)) }
    return result
  }

  private func openMissionControl(on target: TargetDisplay, topology: [DisplaySpaceSnapshot])
    throws
  {
    if !missionControl.isVisible() {
      guard runtime.postSymbolicHotKey(32), wait(until: { missionControl.isVisible() }) else {
        throw EngineError("Could not open Mission Control")
      }
    }
    _ = try missionControl.beginKeyboardNavigation(on: target, topology: topology).get()
  }
}

@MainActor
public func runAtelierEngine() throws {
  setbuf(stdout, nil)
  let processLock = try SingletonProcessLock()
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let bridge = try EngineBridge()
  signal(SIGTERM, SIG_IGN)
  signal(SIGINT, SIG_IGN)
  let signals = [SIGTERM, SIGINT].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
      bridge.cleanup()
      app.terminate(nil)
    }
    source.resume()
    return source
  }
  DispatchQueue.global().async {
    while let line = readLine() {
      DispatchQueue.main.sync {
        MainActor.assumeIsolated { print(bridge.handle(line)) }
      }
    }
    DispatchQueue.main.async {
      bridge.cleanup()
      app.terminate(nil)
    }
  }
  withExtendedLifetime((bridge, processLock, signals)) { app.run() }
}
