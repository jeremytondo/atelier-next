// The experiment is deliberately single-shot. Its durable intent precedes every
// mutation, and ownership requires both a returned ID and an unambiguous census.
import AppKit
import NativeBridge
import Trial

func nativeCensus() throws -> [[String: Any]] {
  guard let census = NativeBridge.census() as? [[String: Any]] else { throw TrialError("Native census unavailable") }
  _ = try Creation.decode(census)
  return census
}

final class MutationLock {
  private let descriptor: Int32
  init() throws {
    descriptor = open("/tmp/com.elevenideas.atelier.space-control.\(getuid()).lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw TrialError("Cannot acquire native Space operation lock") }
    guard lockf(descriptor, F_TLOCK, 0) == 0 else {
      close(descriptor)
      throw TrialError("Another Atelier engine or experiment is running; stop it before a mutation")
    }
  }
  deinit { close(descriptor) }
}

func runCreate(path: String, display requestedDisplay: String?, preflightOnly: Bool = false, engineOwnsLock: Bool = false) throws -> [String: Any] {
  let lock = try engineOwnsLock ? nil : MutationLock()
  return try withExtendedLifetime(lock) {
    guard NSScreen.screens.count == 1 else { throw TrialError("Placement is unproven: mutation currently requires exactly one screen") }
    let probe = NativeBridge.probe() as! [String: Any]
    guard probe["bridgeAnswered"] as? Bool == true, probe["bridgeMatchesCensus"] as? Bool == true,
      probe["createABIAvailable"] as? Bool == true else { throw TrialError("Bridge capability preflight failed") }
    let rawBefore = try nativeCensus(), before = try Creation.decode(rawBefore)
    let display = try Creation.targetDisplay(requested: requestedDisplay, screenCount: NSScreen.screens.count, census: before)
    let sip = commandOutput("/usr/bin/csrutil", ["status"])
    guard sip == "System Integrity Protection status: enabled." else { throw TrialError("Fully enabled SIP was not confirmed: \(sip)") }
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    guard session?[kCGSessionOnConsoleKey as String] as? Bool == true,
      session?[kCGSessionLoginDoneKey as String] as? Bool == true,
      session?["CGSSessionScreenIsLocked"] as? Bool != true else {
      throw TrialError("An unlocked console GUI session is required (console=\(String(describing: session?[kCGSessionOnConsoleKey as String])), login=\(String(describing: session?[kCGSessionLoginDoneKey as String])), locked=\(String(describing: session?["CGSSessionScreenIsLocked"])))")
    }
    if preflightOnly { return ["status": "preflight-passed", "mutationDispatched": false, "before": rawBefore, "probe": probe] }
    let journal = try Journal(path: path, create: true)
    let observation = NativeBridge.observation() as! [String: Any]
    try journal.write("intent.json", ["command": "create", "display": display, "before": rawBefore,
      "observation": observation, "probe": probe, "sip": sip, "pid": getpid(),
      "startedUTC": ISO8601DateFormatter().string(from: Date()), "mayApplyAfterInterruption": true])
    let start = ProcessInfo.processInfo.systemUptime
    var report = NativeBridge.createDesktop() as! [String: Any]
    report["dispatchMilliseconds"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
    // Preserve the returned ID before doing any confirmation or activation work.
    try journal.write("dispatch.json", report)
    let id = UInt64(report["createdID"] as? String ?? "") ?? 0
    var outcome: Observation = .pending
    repeat {
      let raw = try nativeCensus()
      report["after"] = raw
      outcome = Creation.observe(id: id, display: display, before: before, after: try Creation.decode(raw))
      if outcome != .pending { break }
      RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    } while ProcessInfo.processInfo.systemUptime - start < 2
    report["dispatchToNewIDMilliseconds"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
    switch outcome {
    case .verified: report["status"] = "managed-type0-confirmed"
    case .pending: report["status"] = "uncertain"; report["error"] = "Returned ID not observed within two seconds; do not replay"
    case .rejected(let reason): report["status"] = "uncertain"; report["error"] = reason
    }
    let afterObservation = NativeBridge.observation() as! [String: Any]
    report["observationAfter"] = afterObservation
    report["pointerUnchanged"] = NSDictionary(dictionary: observation["pointer"] as? [String: Any] ?? [:]).isEqual(to: afterObservation["pointer"] as? [String: Any] ?? [:])
    report["focusUnchanged"] = observation["focusKnown"] as? Bool == true && afterObservation["focusKnown"] as? Bool == true &&
      observation["frontPID"] as? Int == afterObservation["frontPID"] as? Int && observation["focusedWindow"] as? Int == afterObservation["focusedWindow"] as? Int
    let oldMemberships = observation["memberships"] as? [String: [NSNumber]] ?? [:]
    let newMemberships = afterObservation["memberships"] as? [String: [NSNumber]] ?? [:]
    report["existingMembershipsUnchanged"] = observation["windowQueryComplete"] as? Bool == true &&
      afterObservation["windowQueryComplete"] as? Bool == true && oldMemberships.allSatisfy { newMemberships[$0.key] == $0.value }
    report["runDirectory"] = journal.directory.path
    try journal.write("result.json", report)
    return report
  }
}

func reconcile(path: String) throws -> [String: Any] {
  let journal = try Journal(path: path, create: false), intent = try journal.read("intent.json")
  let dispatch = try? journal.read("dispatch.json")
  let raw = try nativeCensus(), after = try Creation.decode(raw)
  let before = try Creation.decode(intent["before"] as? [[String: Any]] ?? [])
  let oldIDs = Set(before.flatMap { $0.spaces.map(\.id) })
  return ["command": "reconcile", "mutationDispatched": false, "after": raw,
    "returnedID": dispatch?["createdID"] ?? NSNull(),
    "newIDs": after.flatMap { $0.spaces.map(\.id) }.filter { !oldIDs.contains($0) }.map(String.init),
    "instruction": "Read only. No request is replayed and no uncertain ownership is inferred."]
}

func runCleanup(path: String, engineOwnsLock: Bool = false, reconciledDisplay: String? = nil) throws -> [String: Any] {
  let lock = try engineOwnsLock ? nil : MutationLock()
  return try withExtendedLifetime(lock) {
    let journal = try Journal(path: path, create: false), intent = try journal.read("intent.json"), result = try journal.read("result.json")
    let dispatch = try journal.read("dispatch.json")
    guard ["created-verified", "managed-type0-confirmed"].contains(result["status"] as? String ?? ""), let stringID = result["createdID"] as? String,
      dispatch["createdID"] as? String == stringID, let id = UInt64(stringID), id > 0
    else { throw TrialError("Cleanup requires a returned, unambiguously verified run-owned ID") }
    let before = try Creation.decode(intent["before"] as? [[String: Any]] ?? [])
    guard !before.contains(where: { $0.spaces.contains(where: { $0.id == id }) }) else { throw TrialError("Refusing to delete an original Desktop") }
    let raw = try nativeCensus(), fresh = try Creation.decode(raw)
    guard let display = fresh.first(where: { $0.spaces.contains(where: { $0.id == id }) }) else {
      return ["status": "already-absent", "createdID": stringID, "mutationDispatched": false, "after": raw]
    }
    let expectedDisplay = reconciledDisplay ?? (intent["display"] as? String ?? "")
    let savedRecord = (result["after"] as? [[String: Any]] ?? []).flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }
      .first { ($0["id64"] as? NSNumber)?.uint64Value == id }
    let currentRecord = raw.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }
      .first { ($0["id64"] as? NSNumber)?.uint64Value == id }
    guard let uuid = savedRecord?["uuid"] as? String, !uuid.isEmpty, currentRecord?["uuid"] as? String == uuid else {
      throw TrialError("The saved native Space UUID no longer matches; cleanup ownership is uncertain")
    }
    guard display.identifier == expectedDisplay,
      display.currentSpaceID != id, display.spaces.first(where: { $0.id == id })?.rawType == 0,
      display.spaces.filter({ $0.rawType == 0 }).count > 1 else { throw TrialError("Owned Desktop changed display/type, is active, or is the last Desktop") }
    var occupancy = NativeBridge.occupancy(id) as! [String: Any]
    let observation = intent["observation"] as? [String: Any] ?? [:]
    let baselineMemberships = observation["memberships"] as? [String: [NSNumber]] ?? [:]
    let baselineWindows = observation["windows"] as? [String: [String: Any]] ?? [:]
    let occupants = occupancy["blockers"] as? [[String: Any]] ?? []
    let retained = occupants.filter { Cleanup.retainsBaseline(window: $0, ownedID: id,
      baselineMemberships: baselineMemberships, baselineWindows: baselineWindows) }
    occupancy["retainedBaselineOccupants"] = retained
    guard occupancy["empty"] as? Bool == true || (occupancy["error"] == nil && retained.count == occupants.count) else {
      return ["status": "cleanup-refused", "createdID": stringID, "occupancy": occupancy, "mutationDispatched": false]
    }
    guard try Creation.decode(nativeCensus()) == fresh else { throw TrialError("Topology changed during occupancy check") }
    try journal.write("cleanup-intent.json", ["createdID": stringID, "spaceUUID": uuid, "before": raw,
      "originalDisplay": intent["display"] ?? NSNull(), "reconciledDisplay": reconciledDisplay ?? "",
      "occupancy": occupancy, "mayApplyAfterInterruption": true])
    var report = NativeBridge.destroyDesktop(id) as! [String: Any]
    report["createdID"] = stringID
    try journal.write("cleanup-dispatch.json", report)
    let start = ProcessInfo.processInfo.systemUptime
    var after = raw
    repeat {
      after = try nativeCensus()
      if try !Creation.decode(after).contains(where: { $0.spaces.contains(where: { $0.id == id }) }) { break }
      RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    } while ProcessInfo.processInfo.systemUptime - start < 2
    let topology = try Creation.decode(after)
    report["after"] = after
    report["status"] = topology.contains(where: { $0.spaces.contains(where: { $0.id == id }) }) ? "cleanup-uncertain" : "removed"
    report["originalTopologyRestored"] = topology == before
    report["occupancy"] = occupancy
    report["observationAfter"] = NativeBridge.observation()
    try journal.write("cleanup-result.json", report)
    return report
  }
}
