// ATE-40's confirmation rules. Only an exact new managed type-0 ID proves
// creation. Any other topology change is evidence to retain, never to repair.
import Foundation
import CoreFoundation
import SpaceControlCore

public enum Observation: Equatable {
  case pending
  case verified
  case rejected(String)
}

public enum Creation {
  public static func decode(_ raw: [[String: Any]]) throws -> [DisplaySpaceSnapshot] {
    func integer(_ value: Any?) -> UInt64? {
      guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
        !CFNumberIsFloatType(unsafeBitCast(n, to: CFNumber.self)),
        let result = UInt64(n.stringValue) else { return nil }
      return result
    }
    var displayIDs = Set<String>(), spaceIDs = Set<UInt64>()
    guard !raw.isEmpty else { throw TrialError("Empty topology") }
    for display in raw {
      guard let identifier = display["Display Identifier"] as? String, !identifier.isEmpty,
        displayIDs.insert(identifier).inserted,
        let spaces = display["Spaces"] as? [[String: Any]], !spaces.isEmpty,
        let current = display["Current Space"] as? [String: Any],
        let currentID = integer(current["ManagedSpaceID"] ?? current["id64"])
      else { throw TrialError("Incomplete display census") }
      var containsCurrent = false
      for space in spaces {
        guard let id = integer(space["ManagedSpaceID"] ?? space["id64"]), id > 0,
          spaceIDs.insert(id).inserted, integer(space["type"]) != nil,
          space["ManagedSpaceID"] == nil || space["id64"] == nil || integer(space["ManagedSpaceID"]) == integer(space["id64"])
        else { throw TrialError("Invalid or duplicate native Space record") }
        containsCurrent = containsCurrent || id == currentID
      }
      guard containsCurrent else { throw TrialError("Current Space absent from census") }
    }
    return SpaceTopology.decode(raw)
  }

  public static func observe(id: UInt64, display: String, before: [DisplaySpaceSnapshot],
    after: [DisplaySpaceSnapshot]) -> Observation {
    guard id > 0 else { return .rejected("No returned ID; mutation outcome is uncertain") }
    let oldIDs = Set(before.flatMap { $0.spaces.map(\.id) })
    guard !oldIDs.contains(id) else { return .rejected("Returned ID existed before the request") }
    guard before.map(\.identifier) == after.map(\.identifier),
      before.contains(where: { $0.identifier == display }) else {
      return .rejected("Target display absent or display configuration changed")
    }
    for (old, fresh) in zip(before, after) {
      guard fresh.spaces.filter({ oldIDs.contains($0.id) }) == old.spaces else {
        return .rejected("Existing Space order, type, or display membership changed")
      }
      guard old.currentSpaceID == fresh.currentSpaceID else {
        return .rejected("Creation changed the active Space or raced with native input")
      }
    }
    let added = after.flatMap { d in d.spaces.filter { !oldIDs.contains($0.id) }.map { (d.identifier, $0) } }
    if added.isEmpty { return .pending }
    guard added.count == 1, added[0].1.id == id else { return .rejected("Ambiguous addition or wrong returned ID") }
    guard added[0].0 == display else { return .rejected("Created on the wrong display") }
    guard added[0].1.rawType == 0, !added[0].1.isFullscreen else { return .rejected("Created Space is not a managed type-0 Desktop") }
    return .verified
  }
}

public struct TrialError: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
