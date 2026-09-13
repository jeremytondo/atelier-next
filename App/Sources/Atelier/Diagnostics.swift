import AppKit
import AtelierCore

@MainActor
final class Diagnostics {
  struct Event: Codable {
    let at: Date
    let name: String
    let milliseconds: Double?
    let detail: String?
  }
  private(set) var events: [Event] = []
  private let logURL: URL
  init() {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Logs/Atelier")
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    logURL = directory.appendingPathComponent("events.jsonl")
  }
  func record(_ name: String, ms: Double? = nil, detail: String? = nil) {
    let event = Event(at: Date(), name: name, milliseconds: ms, detail: detail)
    events.append(event)
    if events.count > 300 { events.removeFirst(events.count - 300) }
    guard let data = try? JSONEncoder().encode(event) else { return }
    if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 262_144 {
      let old = logURL.deletingLastPathComponent().appendingPathComponent("events.previous.jsonl")
      try? FileManager.default.removeItem(at: old)
      try? FileManager.default.moveItem(at: logURL, to: old)
    }
    if !FileManager.default.fileExists(atPath: logURL.path) {
      FileManager.default.createFile(
        atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    if let handle = try? FileHandle(forWritingTo: logURL) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data + Data([10]))
    }
  }
  func data(
    state: String, error: String?, snapshot: Snapshot?, groups: [WindowGroup], helperPID: Int32?,
    includeTitles: Bool = false
  ) throws -> Data {
    struct Export: Encodable {
      let version: String, build: String, channel: String, commit: String, os: String, state: String
      let error: String?
      let accessibility: Bool
      let helperPID: Int32?
      let snapshot: Snapshot?
      let groups: [WindowGroup]
      let events: [Event]
    }
    var snapshot = snapshot
    var groups = groups
    if !includeTitles {
      if let count = snapshot?.windows.count {
        for i in 0..<count { snapshot?.windows[i].title = "" }
      }
      for i in groups.indices {
        for j in groups[i].members.indices { groups[i].members[j].title = "" }
      }
    }
    let payload = Export(
      version: Bundle.main.object(forInfoDictionaryKey: "AtelierBuildVersion") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "dev",
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
      channel: Bundle.main.object(forInfoDictionaryKey: "AtelierBuildChannel") as? String ?? "local",
      commit: Bundle.main.object(forInfoDictionaryKey: "AtelierBuildCommit") as? String ?? "unknown",
      os: ProcessInfo.processInfo.operatingSystemVersionString, state: state, error: error,
      accessibility: AXIsProcessTrusted(), helperPID: helperPID, snapshot: snapshot, groups: groups,
      events: events)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(payload)
  }
}
