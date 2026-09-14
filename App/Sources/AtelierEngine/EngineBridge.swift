import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import DesktopBridge
import Foundation
import SpaceControlCore

/// The helper's command dispatch and its Space operations. Native mechanisms
/// only: no hotkeys, group policy, or persistent preferences.
@MainActor
final class EngineBridge {
  private let api: PrivateAPI
  private let runtime: SpaceRuntime
  private let resolver = TargetDisplayResolver()
  private let windows: WindowInventory
  private let missionControl: MissionControl
  private let quickApps: QuickApps
  private let poller = Poller.live(interval: 0.02)

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
      MembershipResponse(
        spaces: self.windows.spaces(of: request.window), focused: self.windows.focusedWindowID())
    },
    "switch": trusted { (request: SpaceRequest) in try self.switchDesktop(request) },
    "create": trusted { (request: SpaceRequest) in try self.createDesktop(request) },
    "reorder": trusted { (request: SpaceRequest) in try self.reorderDesktop(request) },
    "delete": trusted { (request: SpaceRequest) in try self.deleteDesktop(request) },
    "quickToggle": trusted { (request: QuickToggleRequest) in try self.quickApps.toggle(request) },
  ]

  init() throws {
    api = try PrivateAPI()
    runtime = SpaceRuntime(api: api)
    windows = WindowInventory(api: api)
    missionControl = MissionControl(
      seams: .live(runtime: runtime, poller: .live(interval: 0.05)))
    quickApps = QuickApps(
      seams: .live(
        runtime: runtime, resolver: resolver, windows: windows,
        assignment: SpaceAssignment(api: api, poller: .live(interval: 0.04)),
        poller: .live(interval: 0.04)))
  }

  func handle(_ line: String) -> String {
    HelperProtocol.respond(to: line, using: commands)
  }

  func cleanup() {
    runtime.restoreTemporarilyEnabledHotKeys()
    missionControl.resetPointer()
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

  private func snapshot() -> Snapshot {
    let topology = runtime.snapshot()
    let trusted = AXIsProcessTrusted()
    return Snapshot(
      trusted: trusted, focused: windows.focusedWindowID(),
      targetDisplay: resolver.resolve(in: topology)?.topologyIdentifier ?? "",
      missionControl: missionControl.isVisible(),
      displays: topology.map { display in
        Snapshot.Display(
          id: display.identifier, current: String(display.currentSpaceID),
          spaces: display.spaces.map {
            Snapshot.Space(id: String($0.id), fullscreen: $0.isFullscreen)
          })
      },
      windows: trusted ? windows.onScreenWindows() : [])
  }

  // MARK: - Space operations

  /// The display and Desktop a Space operation acts on, refusing when either
  /// moved since the JavaScript side observed them.
  private func spaceTarget(_ request: SpaceRequest) throws -> (
    target: TargetDisplay, display: DisplaySpaceSnapshot, topology: [DisplaySpaceSnapshot]
  ) {
    let topology = runtime.snapshot()
    guard let target = resolver.resolve(in: topology),
      let display = topology.first(where: { $0.identifier == target.topologyIdentifier })
    else { throw EngineError("No target display") }
    if let expected = request.display, expected != target.topologyIdentifier {
      throw EngineError("Target display changed before operation")
    }
    if let expected = request.current, expected != String(display.currentSpaceID) {
      throw EngineError("Active Space changed before operation")
    }
    return (target, display, topology)
  }

  private func switchDesktop(_ request: SpaceRequest) throws -> any Encodable {
    let (target, display, topology) = try spaceTarget(request)
    guard let number = request.number else { throw EngineError("number required") }
    guard
      let desktop = SpaceTopology.desktop(
        number: number, on: target.topologyIdentifier, displays: topology)
    else { return NoopResponse() }
    if desktop.id != display.currentSpaceID {
      let posted = poller.now()
      guard let global = SpaceTopology.globalDesktopNumber(for: desktop.id, displays: topology),
        global <= DesktopCreation.maximumNumberedDesktop,
        runtime.postSymbolicHotKey(SymbolicHotKey.desktop(global))
      else { throw EngineError("Native Desktop shortcut unavailable") }
      guard
        poller.wait(
          3,
          until: {
            runtime.currentSpaceID(on: target.topologyIdentifier) == desktop.id
          })
      else { throw EngineError("Native shortcut sent but destination was not verified") }
      // Keep a temporarily enabled shortcut registered until macOS has matched the event.
      poller.sleep(0.27 - (poller.now() - posted))
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
    guard api.canCountDockDesktops else {
      throw EngineError("Dock's Desktop count is unavailable on this macOS")
    }
    let seams = DesktopCreationSeams(
      topology: { self.runtime.snapshot() },
      missionControlVisible: { self.missionControl.isVisible() },
      dockCount: { self.api.dockDesktopCount() },
      create: {
        let report = DesktopBridge.createDesktop()
        if let id = (report["createdID"] as? NSNumber)?.uint64Value { return .created(id) }
        let reason = report["error"] as? String ?? "Desktop creation failed"
        return report["dispatched"] as? Bool == true ? .uncertain(reason) : .refused(reason)
      },
      enterDesktop: { self.runtime.postSymbolicHotKey(SymbolicHotKey.desktop($0)) },
      poller: poller)
    let created = try DesktopCreation.createAndEnter(on: target.topologyIdentifier, seams: seams)
    var result = snapshot()
    result.created = String(created)
    return result
  }

  private func reorderDesktop(_ request: SpaceRequest) throws -> Snapshot {
    let (target, _, topology) = try spaceTarget(request)
    guard let offset = request.offset, abs(offset) == 1 else {
      throw EngineError("offset must be -1 or 1")
    }
    defer { cleanup() }
    try missionControl.open(on: target, topology: topology)
    try missionControl.reorderActiveDesktop(
      offset: offset, on: target, topology: runtime.snapshot())
    try missionControl.enterActiveDesktop(on: target, topology: runtime.snapshot())
    return snapshot()
  }

  private func deleteDesktop(_ request: SpaceRequest) throws -> Snapshot {
    let (target, display, topology) = try spaceTarget(request)
    guard display.regularDesktops.count > 1 else {
      throw EngineError("The final Desktop cannot be deleted")
    }
    let deleted = String(display.currentSpaceID)
    let departing = windows.onScreenWindows().filter { $0.space == deleted }.map(\.id)
    defer { cleanup() }
    try missionControl.open(on: target, topology: topology)
    try missionControl.deleteActiveDesktop(on: target, topology: runtime.snapshot())
    try missionControl.enterActiveDesktop(on: target, topology: runtime.snapshot())
    var result = snapshot()
    guard
      poller.wait(
        3,
        until: {
          departing.allSatisfy { window in
            let spaces = windows.spaces(of: window)
            return !spaces.isEmpty && !spaces.contains(deleted)
          }
        })
    else {
      throw EngineError(
        "Desktop deleted, but could not verify all eligible windows survived on another Space")
    }
    result.migratedWindows = departing.map {
      Snapshot.WindowSpaces(id: $0, spaces: windows.spaces(of: $0))
    }
    return result
  }
}

/// One engine per user: a second instance would post duplicate events and
/// fight over temporary shortcut state.
final class SingletonProcessLock {
  private let descriptor: Int32

  init() throws {
    let path = "/tmp/com.elevenideas.atelier.engine.\(getuid()).lock"
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw EngineError("Could not open the engine process lock") }
    guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
      close(descriptor)
      throw EngineError("Another Atelier engine is running. Stop it before resuming Atelier.")
    }
    self.descriptor = descriptor
  }

  deinit {
    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
    close(descriptor)
  }
}

/// Serves JSON-lines requests from stdin on the main thread until stdin closes
/// or a termination signal arrives, restoring shortcut and pointer state first.
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
