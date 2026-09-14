// Deletion cannot displace an exclusive occupant. A pre-existing window that
// gained the new ID is safe only while every original membership is retained;
// this is not inferred from on-screen visibility or app name.
import Foundation

public enum Cleanup {
  public static func retainsBaseline(window: [String: Any], ownedID: UInt64,
    baselineMemberships: [String: [NSNumber]], baselineWindows: [String: [String: Any]]) -> Bool {
    guard let id = window["id"] as? NSNumber,
      let old = baselineMemberships[id.stringValue], !old.isEmpty,
      let current = window["spaces"] as? [NSNumber], current.contains(NSNumber(value: ownedID))
    else { return false }
    if let identity = baselineWindows[id.stringValue], identity["pid"] as? NSNumber != window["pid"] as? NSNumber { return false }
    return Set(current.map(\.uint64Value)).subtracting([ownedID]) == Set(old.map(\.uint64Value))
  }
}
