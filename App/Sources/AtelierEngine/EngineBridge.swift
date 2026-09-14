import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import DesktopBridge
import Foundation
import QuickAppSupport
import SpaceControlCore

/// Opt-in command seam for isolated native experiments. A nil result delegates
/// to the normal engine. Installed Atelier supplies no extension.
public typealias NativeCommandExtension = @MainActor (String, [String: Any]) throws -> [String: Any]?

struct BridgeError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

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
  private let commandExtension: NativeCommandExtension?

  let quickAssignment = SpaceAssignmentCoordinator()
  var quickStates: [String: QuickAppState] = [:]

  init(stateDirectory: URL? = nil, commandExtension: NativeCommandExtension? = nil) throws {
    self.commandExtension = commandExtension
    runtime = try SpaceRuntime(stateDirectory: stateDirectory)
    guard
      let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
      let ax = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
      let c = dlsym(sky, "SLSMainConnectionID"),
      let m = dlsym(sky, "SLSCopySpacesForWindows"),
      let w = dlsym(ax, "_AXUIElementGetWindow")
    else {
      throw BridgeError(message: "Required native window identity/Space symbols unavailable")
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

  func frame(_ element: AXUIElement) -> [String: Double]? {
    guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
      let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &point),
      AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size)
    else { return nil }
    return ["x": point.x, "y": point.y, "w": size.width, "h": size.height]
  }

  private func inventory() -> [[String: Any]] {
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
      return [
        "id": wid, "pid": pid, "space": membership[0], "frame": rect,
        "title": attribute(window, kAXTitleAttribute) as? String ?? "",
        "app": running.localizedName ?? "", "bundleID": running.bundleIdentifier ?? "",
      ]
    }
  }

  private func snapshot() -> [String: Any] {
    let topology = runtime.snapshot()
    let target = resolver.resolve(in: topology)
    return [
      "trusted": AXIsProcessTrusted(), "pid": getpid(), "focused": focusedID(),
      "targetDisplay": target?.topologyIdentifier ?? "",
      "missionControl": missionControl.isVisible(),
      "displays": topology.map { d -> [String: Any] in
        [
          "id": d.identifier, "current": String(d.currentSpaceID),
          "spaces": d.spaces.map {
            ["id": String($0.id), "fullscreen": $0.isFullscreen] as [String: Any]
          },
        ]
      }, "windows": AXIsProcessTrusted() ? inventory() : [],
    ]
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

  func handle(_ line: String) async {
    let started = ProcessInfo.processInfo.systemUptime
    var response: [String: Any] = [:]
    do {
      guard line.utf8.count < 65536,
        let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let command = request["command"] as? String
      else { throw BridgeError(message: "Invalid JSON request") }
      response["id"] = request["id"] ?? NSNull()
      if command == "quickToggle" {
        guard AXIsProcessTrusted() else {
          throw BridgeError(message: "Accessibility permission required for quick apps")
        }
        response["result"] = try await toggleQuickApp(request)
      } else {
        response["result"] = try execute(command, request)
      }
      response["ok"] = true
    } catch {
      response["ok"] = false
      response["error"] = error.localizedDescription
    }
    response["milliseconds"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
    if let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    {
      print(string)
    }
  }

  private func execute(_ command: String, _ request: [String: Any]) throws -> [String: Any] {
    if let result = try commandExtension?(command, request) { return result }
    if command == "hello" {
      return ["protocolVersion": 1, "pid": getpid(), "trusted": AXIsProcessTrusted()]
    }
    if command == "probe" || command == "snapshot" { return snapshot() }
    if command == "quickResolve" {
      guard let name = request["app"] as? String else { throw BridgeError(message: "app required") }
      let target = try TargetApplication.resolve(name)
      return ["bundleID": target.bundleIdentifier, "name": target.name]
    }
    if command == "membership" {
      guard let wid = request["window"] as? UInt32 else {
        throw BridgeError(message: "window required")
      }
      return ["spaces": spaces(wid), "focused": focusedID()]
    }
    guard AXIsProcessTrusted() else {
      throw BridgeError(
        message: "Accessibility permission required for the helper's responsible app")
    }
    let before = runtime.snapshot()
    guard let target = resolver.resolve(in: before),
      let display = before.first(where: { $0.identifier == target.topologyIdentifier })
    else { throw BridgeError(message: "No target display") }
    if let expected = request["display"] as? String, expected != target.topologyIdentifier {
      throw BridgeError(message: "Target display changed before operation")
    }
    if let expected = request["current"] as? String, expected != String(display.currentSpaceID) {
      throw BridgeError(message: "Active Space changed before operation")
    }
    if command == "send" {
      throw BridgeError(message: "Window movement between Spaces is not supported")
    }
    if command == "switch" {
      guard let number = request["number"] as? Int,
        let desktop = SpaceTopology.desktop(
          number: number, on: target.topologyIdentifier, displays: before)
      else { return ["noop": true] }
      if desktop.id != display.currentSpaceID {
        let restoreDeadline = Date().addingTimeInterval(0.27)
        guard let global = SpaceTopology.globalDesktopNumber(for: desktop.id, displays: before),
          global <= 16,
          runtime.postSymbolicHotKey(UInt32(117 + global))
        else { throw BridgeError(message: "Native Desktop shortcut unavailable") }
        guard
          wait(until: {
            runtime.snapshot().first(where: { $0.identifier == target.topologyIdentifier })?
              .currentSpaceID == desktop.id
          })
        else { throw BridgeError(message: "Native shortcut sent but destination was not verified") }
        if Date() < restoreDeadline { RunLoop.current.run(until: restoreDeadline) }
      }
      // Restore temporary symbolic registrations before the app reenables its bindings.
      runtime.restoreTemporarilyEnabledHotKeys()
      return snapshot()
    }
    guard ["create", "reorder", "delete"].contains(command) else {
      throw BridgeError(message: "Unknown command: \(command)")
    }
    if command == "reorder", ![-1, 1].contains(request["offset"] as? Int ?? 0) {
      throw BridgeError(message: "offset must be -1 or 1")
    }
    if command == "delete" && display.regularDesktops.count <= 1 {
      throw BridgeError(message: "The final Desktop cannot be deleted")
    }
    let departingWindows =
      command == "delete"
      ? inventory().filter { $0["space"] as? String == String(display.currentSpaceID) }.compactMap {
        $0["id"] as? UInt32
      }
      : []
    defer { cleanup() }
    if command == "create" {
      guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
        throw BridgeError(message: "Desktop creation requires macOS 27")
      }
      if let reason = DesktopBridge.unavailableReason() { throw BridgeError(message: reason) }
      let created = try DesktopCreation.createAndEnter(
        on: target.topologyIdentifier, seams: creationSeams())
      var result = snapshot()
      result["created"] = String(created.id)
      result["creation"] = [
        "millisecondsToEntryDispatch": created.secondsToEntryDispatch * 1000,
        "millisecondsTotal": created.secondsTotal * 1000,
      ]
      return result
    }
    if !missionControl.isVisible() {
      guard runtime.postSymbolicHotKey(32), wait(until: { missionControl.isVisible() }) else {
        throw BridgeError(message: "Could not open Mission Control")
      }
    }
    _ = try missionControl.beginKeyboardNavigation(on: target, topology: before).get()
    if command == "reorder" {
      guard let offset = request["offset"] as? Int, abs(offset) == 1 else {
        throw BridgeError(message: "offset must be -1 or 1")
      }
      _ = try missionControl.reorderActiveDesktop(
        offset: offset, on: target, topology: runtime.snapshot()
      ).get()
    } else {
      _ = try missionControl.deleteActiveDesktop(on: target, topology: runtime.snapshot()).get()
    }
    _ = try missionControl.enterActiveDesktop(on: target, topology: runtime.snapshot()).get()
    var result = snapshot()
    if command == "delete" {
      guard
        wait(until: {
          departingWindows.allSatisfy { window in
            let memberships = spaces(window)
            return !memberships.isEmpty && !memberships.contains(String(display.currentSpaceID))
          }
        })
      else {
        throw BridgeError(
          message:
            "Desktop deleted, but could not verify all eligible windows survived on another Space")
      }
      result["migratedWindows"] = departingWindows.map {
        ["id": $0, "spaces": spaces($0)] as [String: Any]
      }
    }
    return result
  }
}

@MainActor
public func runAtelierEngine(stateDirectory: URL? = nil, commandExtension: NativeCommandExtension? = nil) throws {
  setbuf(stdout, nil)
  let processLock = try SingletonProcessLock()
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let bridge = try EngineBridge(stateDirectory: stateDirectory, commandExtension: commandExtension)
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
      let done = DispatchSemaphore(value: 0)
      Task { @MainActor in
        await bridge.handle(line)
        done.signal()
      }
      done.wait()
    }
    DispatchQueue.main.async {
      bridge.cleanup()
      app.terminate(nil)
    }
  }
  withExtendedLifetime((bridge, processLock, signals)) { app.run() }
}
