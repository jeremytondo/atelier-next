// Read-only comparison of WindowServer records and saved Desktop configuration.
// Saved preferences may lag live state; they are evidence, never cleanup authority.
import Foundation
import NativeBridge

func diagnose(path: String) throws -> [String: Any] {
  var report = try reconcile(path: path)
  report["command"] = "diagnose"
  report["date"] = ISO8601DateFormatter().string(from: Date())
  report["bridgeTrace"] = NativeBridge.traceProbe()
  let spaces = (report["after"] as? [[String: Any]] ?? []).flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }
  report["spaceValues"] = spaces.compactMap { space -> [String: Any]? in
    guard let id = space["id64"] as? NSNumber else { return nil }
    return ["spaceID": id.stringValue, "record": NativeBridge.spaceValues(id.uint64Value)]
  }
  if let configuration = CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString,
    "com.apple.spaces" as CFString) as? [String: Any] {
    report["savedDisplayConfiguration"] = configuration
    let management = configuration["Management Data"] as? [String: Any] ?? [:]
    let monitors = management["Monitors"] as? [[String: Any]] ?? []
    let savedIDs = monitors.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }
      .compactMap { ($0["id64"] as? NSNumber)?.stringValue }
    report["savedSpaceIDs"] = savedIDs
    report["returnedIDInSavedConfiguration"] = savedIDs.contains(report["returnedID"] as? String ?? "")
  } else {
    report["savedConfigurationError"] = "Saved Desktop configuration unavailable"
  }
  report["instruction"] = "Read only. WindowServer membership and saved preferences do not establish Mission Control visibility. No mutations or preference synchronization requested."
  return report
}
