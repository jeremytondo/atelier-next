// Explicit Mission Control comparison, separate from WMBridge creation. The
// operator saves the successful native create response before requesting removal.
import Foundation
import NativeBridge
import Trial

func prepareNativeControl(command: String, path: String, request: [String: Any]) throws {
  guard let display = request["display"] as? String, let current = request["current"] as? String else {
    throw TrialError("Native control requires explicit display/current guards")
  }
  _ = try runCreate(path: "", display: display, preflightOnly: true, engineOwnsLock: true)
  let raw = try nativeCensus(), topology = try Creation.decode(raw)
  guard String(topology[0].currentSpaceID) == current, topology[0].spaces.allSatisfy({ $0.rawType == 0 }) else {
    throw TrialError("Native control topology changed or contains fullscreen Spaces")
  }
  let journal = try Journal(path: path, create: command == "create")
  if command == "create" {
    try journal.write("native-create-intent.json", ["before": raw, "observation": NativeBridge.observation(),
      "display": display, "current": current, "mayApplyAfterInterruption": true])
    return
  }
  let intent = try journal.read("native-create-intent.json"), result = try journal.read("native-create-result.json")
  let before = try Creation.decode(intent["before"] as? [[String: Any]] ?? [])
  guard result["ok"] as? Bool == true, let response = result["result"] as? [String: Any],
    let idString = response["created"] as? String, idString == current, let id = UInt64(idString),
    !before.flatMap({ $0.spaces }).contains(where: { $0.id == id }),
    let recorded = result["verifiedRecord"] as? [String: Any],
    let uuid = recorded["uuid"] as? String, !uuid.isEmpty,
    let fresh = (raw[0]["Spaces"] as? [[String: Any]])?.first(where: { ($0["id64"] as? NSNumber)?.uint64Value == id }),
    fresh["uuid"] as? String == uuid,
    Set(topology[0].spaces.map(\.id)) == Set(before[0].spaces.map(\.id) + [id]) else {
    throw TrialError("Native control deletion requires its successful create response and matching fresh UUID")
  }
  let occupancy = NativeBridge.occupancy(id) as! [String: Any]
  let observation = intent["observation"] as? [String: Any] ?? [:]
  let baselineWindows = observation["windows"] as? [String: [String: Any]] ?? [:]
  // This control removes its active Desktop through Dock. Existing menu-bar
  // status items follow that Desktop; unlike app windows they have no saved
  // document to displace. Require the exact baseline window/PID and status layer.
  func retainedStatusItem(_ window: [String: Any]) -> Bool {
    guard let id = window["id"] as? NSNumber, let old = baselineWindows[id.stringValue] else { return false }
    return window["bundle"] as? String == "com.apple.controlcenter" &&
      old["bundle"] as? String == "com.apple.controlcenter" &&
      window["executable"] as? String == "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter" &&
      window["pid"] as? NSNumber == old["pid"] as? NSNumber &&
      window["layer"] as? Int == 25 && old["layer"] as? Int == 25
  }
  let blockers = occupancy["blockers"] as? [[String: Any]] ?? []
  guard occupancy["error"] == nil, blockers.allSatisfy({ retainedStatusItem($0) || Cleanup.retainsBaseline(window: $0, ownedID: id,
    baselineMemberships: observation["memberships"] as? [String: [NSNumber]] ?? [:],
    baselineWindows: baselineWindows) }),
    try Creation.decode(nativeCensus()) == topology else { throw TrialError("Native control is occupied or changed") }
  try journal.write("native-delete-intent.json", ["createdID": idString, "spaceUUID": uuid,
    "before": raw, "occupancy": occupancy, "mayApplyAfterInterruption": true])
}
