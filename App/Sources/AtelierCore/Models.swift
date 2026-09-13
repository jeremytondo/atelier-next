import Foundation

public struct AppError: LocalizedError, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public struct WindowFrame: Codable, Equatable, Sendable {
  public var x: Double, y: Double, w: Double, h: Double
  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }
  public func matches(_ other: WindowFrame?, tolerance: Double = 1) -> Bool {
    guard let other else { return false }
    return abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
      && abs(w - other.w) <= tolerance && abs(h - other.h) <= tolerance
  }
}

public struct WindowRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: UInt32
  public var pid: Int32
  public var space: String
  public var frame: WindowFrame
  public var title: String
  public var app: String
  public var bundleID: String
  public var key: WindowKey { WindowKey(pid: pid, id: id) }
  public init(
    id: UInt32, pid: Int32, space: String, frame: WindowFrame, title: String = "", app: String = "",
    bundleID: String = ""
  ) {
    self.id = id
    self.pid = pid
    self.space = space
    self.frame = frame
    self.title = title
    self.app = app
    self.bundleID = bundleID
  }
}

public struct WindowKey: Hashable, Codable, Sendable {
  public let pid: Int32
  public let id: UInt32
  public init(pid: Int32, id: UInt32) {
    self.pid = pid
    self.id = id
  }
}

public struct SpaceRecord: Codable, Equatable, Sendable {
  public var id: String
  public var fullscreen: Bool
  public init(id: String, fullscreen: Bool = false) {
    self.id = id
    self.fullscreen = fullscreen
  }
}

public struct DisplayRecord: Codable, Equatable, Sendable {
  public var id: String
  public var current: String
  public var spaces: [SpaceRecord]
  public init(id: String, current: String, spaces: [SpaceRecord]) {
    self.id = id
    self.current = current
    self.spaces = spaces
  }
}

public struct Snapshot: Codable, Sendable {
  public var trusted: Bool
  public var focused: UInt32
  public var targetDisplay: String
  public var missionControl: Bool
  public var displays: [DisplayRecord]
  public var windows: [WindowRecord]
  public init(
    trusted: Bool = true, focused: UInt32, targetDisplay: String, missionControl: Bool = false,
    displays: [DisplayRecord], windows: [WindowRecord]
  ) {
    self.trusted = trusted
    self.focused = focused
    self.targetDisplay = targetDisplay
    self.missionControl = missionControl
    self.displays = displays
    self.windows = windows
  }
  public var target: DisplayRecord? { displays.first { $0.id == targetDisplay } }
  public mutating func exclude(_ bundleIDs: Set<String>) {
    windows.removeAll { bundleIDs.contains($0.bundleID) }
  }
}

public struct GroupKey: Hashable, Codable, Sendable {
  public var display: String
  public var space: String
  public init(display: String, space: String) {
    self.display = display
    self.space = space
  }
}

public struct WindowGroup: Codable, Sendable {
  public var key: GroupKey
  public var members: [WindowRecord]
}

public struct GroupStore {
  public private(set) var groups: [GroupKey: WindowGroup] = [:]
  public init() {}
  public mutating func reconcile(_ snapshot: Snapshot) {
    let live = Set(
      snapshot.displays.flatMap { display in
        display.spaces.map { GroupKey(display: display.id, space: $0.id) }
      })
    groups = groups.filter { live.contains($0.key) }
    for display in snapshot.displays {
      let key = GroupKey(display: display.id, space: display.current)
      guard var group = groups[key] else { continue }
      let windows = snapshot.windows.filter { $0.space == display.current }
      let byKey = Dictionary(windows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
      group.members = group.members.compactMap { byKey[$0.key] }
      let existing = Set(group.members.map(\.key))
      group.members += windows.filter { !existing.contains($0.key) }
      groups[key] = group
    }
  }
  public func current(_ snapshot: Snapshot) -> WindowGroup? {
    guard let target = snapshot.target else { return nil }
    return groups[GroupKey(display: target.id, space: target.current)]
  }
  @discardableResult public mutating func group(_ snapshot: Snapshot) throws -> WindowGroup {
    reconcile(snapshot)
    guard let display = snapshot.target,
      display.spaces.contains(where: { $0.id == display.current && !$0.fullscreen })
    else {
      throw AppError("Choose an ordinary Desktop to create a Group.")
    }
    let key = GroupKey(display: display.id, space: display.current)
    if groups[key] == nil {
      let members = snapshot.windows.filter { $0.space == display.current }.sorted { a, b in
        a.id == snapshot.focused && b.id != snapshot.focused
      }
      guard !members.isEmpty else {
        throw AppError("This Desktop has no eligible windows to group.")
      }
      groups[key] = WindowGroup(key: key, members: members)
    }
    return groups[key]!
  }
  public mutating func reorder(_ key: GroupKey, member: WindowKey, offset: Int) {
    guard var group = groups[key],
      let index = group.members.firstIndex(where: { $0.key == member }),
      group.members.indices.contains(index + offset)
    else { return }
    group.members.insert(group.members.remove(at: index), at: index + offset)
    groups[key] = group
  }
}

/// A new lifecycle generation invalidates every in-flight operation. Observations
/// never acquire the mutation slot; callers check the generation before applying them.
public struct OperationGate {
  public private(set) var generation: UInt64 = 0
  public private(set) var active: String?
  public init() {}
  public mutating func begin(_ name: String) -> UInt64? {
    guard active == nil else { return nil }
    active = name
    return generation
  }
  public mutating func end(_ token: UInt64) { if token == generation { active = nil } }
  public mutating func invalidate() {
    generation &+= 1
    active = nil
  }
}

/// Caches only a stable result after a quiet period, including native tiling's
/// animation. No-motion commands receive a separate grace period.
public struct FillSettlement {
  public private(set) var previous: WindowFrame
  public private(set) var changed = false
  public private(set) var lastChange: Double
  public let started: Double
  public init(frame: WindowFrame, now: Double) {
    previous = frame
    lastChange = now
    started = now
  }
  public mutating func sample(_ frame: WindowFrame, eventAt: Double, now: Double) -> Bool {
    if !frame.matches(previous, tolerance: 0) || eventAt > lastChange {
      changed = true
      lastChange = max(now, eventAt)
      previous = frame
    }
    return changed ? now - lastChange >= 0.1 : now - started >= 0.3
  }
}
