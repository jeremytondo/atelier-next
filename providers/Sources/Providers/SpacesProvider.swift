// Stands in for the `hs.spaces` module Hammerspoon 2 does not have yet:
// topology and window membership, Desktop switch/create/reorder/delete, and
// pinning a window's process to every Desktop. Private SkyLight and Mission
// Control automation live behind it; policy stays in JavaScript.
import AppKit
import ApplicationServices
import CoreGraphics
import DesktopBridge
import Foundation
import SpaceControlCore

@MainActor
final class SpacesProvider {
  private let api: PrivateAPI
  private let runtime: SpaceRuntime
  private let resolver = TargetDisplayResolver()
  private let windows: WindowInventory
  private let missionControl: MissionControl
  private let assignment: SpaceAssignment
  private let poller = Poller.live(interval: 0.02)

  /// Adding a command means one entry here and one typed request/response
  /// pair in PipeProtocol.swift.
  lazy var commands: [String: PipeProtocol.Handler] = [
    "snapshot": PipeProtocol.handler { (_: NoArguments) in self.snapshot() },
    "membership": PipeProtocol.handler { (request: MembershipRequest) in
      MembershipResponse(
        spaces: self.windows.spaces(of: request.window), focused: self.windows.focusedWindowID())
    },
    "switch": requiringAccessibility { (request: SpaceRequest) in try self.switchDesktop(request) },
    "create": requiringAccessibility { (request: SpaceRequest) in try self.createDesktop(request) },
    "reorder": requiringAccessibility { (request: SpaceRequest) in
      try self.reorderDesktop(request)
    },
    "delete": requiringAccessibility { (request: SpaceRequest) in try self.deleteDesktop(request) },
    "pin": requiringAccessibility { (request: PinRequest) in try self.pin(request) },
  ]

  init() throws {
    api = try PrivateAPI()
    runtime = SpaceRuntime(api: api)
    windows = WindowInventory(api: api)
    missionControl = MissionControl(
      seams: .live(runtime: runtime, poller: .live(interval: 0.05)))
    assignment = SpaceAssignment(api: api, poller: .live(interval: 0.04))
  }

  func cleanup() {
    runtime.restoreTemporarilyEnabledHotKeys()
    missionControl.resetPointer()
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

  /// The display and Desktop a Space operation acts on, refusing when either
  /// moved since the JavaScript side observed them.
  private func spaceTarget(_ request: SpaceRequest) throws -> (
    target: TargetDisplay, display: DisplaySpaceSnapshot, topology: [DisplaySpaceSnapshot]
  ) {
    let topology = runtime.snapshot()
    guard let target = resolver.resolve(in: topology),
      let display = topology.first(where: { $0.identifier == target.topologyIdentifier })
    else { throw ProviderError("No target display") }
    if let expected = request.display, expected != target.topologyIdentifier {
      throw ProviderError("Target display changed before operation")
    }
    if let expected = request.current, expected != String(display.currentSpaceID) {
      throw ProviderError("Active Space changed before operation")
    }
    return (target, display, topology)
  }

  private func switchDesktop(_ request: SpaceRequest) throws -> any Encodable {
    let (target, display, topology) = try spaceTarget(request)
    guard let number = request.number else { throw ProviderError("number required") }
    guard
      let desktop = SpaceTopology.desktop(
        number: number, on: target.topologyIdentifier, displays: topology)
    else { return NoopResponse() }
    if desktop.id != display.currentSpaceID {
      let posted = poller.now()
      guard let global = SpaceTopology.globalDesktopNumber(for: desktop.id, displays: topology),
        global <= DesktopCreation.maximumNumberedDesktop,
        runtime.postSymbolicHotKey(SymbolicHotKey.desktop(global))
      else { throw ProviderError("Native Desktop shortcut unavailable") }
      guard
        poller.wait(
          3,
          until: {
            runtime.currentSpaceID(on: target.topologyIdentifier) == desktop.id
          })
      else { throw ProviderError("Native shortcut sent but destination was not verified") }
      // Keep a temporarily enabled shortcut registered until macOS has matched the event.
      poller.sleep(0.27 - (poller.now() - posted))
    }
    // Restore temporary symbolic registrations before the defaults reenable their bindings.
    runtime.restoreTemporarilyEnabledHotKeys()
    return snapshot()
  }

  private func createDesktop(_ request: SpaceRequest) throws -> Snapshot {
    let (target, _, _) = try spaceTarget(request)
    defer { cleanup() }
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
      throw ProviderError("Desktop creation requires macOS 27")
    }
    if let reason = DesktopBridge.unavailableReason() { throw ProviderError(reason) }
    guard api.canCountDockDesktops else {
      throw ProviderError("Dock's Desktop count is unavailable on this macOS")
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
      throw ProviderError("offset must be -1 or 1")
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
      throw ProviderError("The final Desktop cannot be deleted")
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
      throw ProviderError(
        "Desktop deleted, but could not verify all eligible windows survived on another Space")
    }
    result.migratedWindows = departing.map {
      Snapshot.WindowSpaces(id: $0, spaces: windows.spaces(of: $0))
    }
    return result
  }

  private func pin(_ request: PinRequest) throws -> PinResponse {
    let target = try TargetApplication.resolve(request.app)
    let outcome = try assignment.ensureAllDesktops(
      pid: request.pid, window: request.window, target: target,
      requiredSpaceIDs: Set(request.spaces))
    return PinResponse(assignment: outcome.message)
  }
}
