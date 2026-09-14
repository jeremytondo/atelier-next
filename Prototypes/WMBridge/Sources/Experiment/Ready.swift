// Composes the tested mechanisms without opening Mission Control. Creation and
// placement preserve the starting Desktop. Observe native Dock registration
// before using the display workaround; entry verifies one native adjacent action.
import AppKit
import NativeBridge
import Trial

func adjacentBinding(forward: Bool) throws -> [String: Any] {
  guard let binding = (NativeBridge.navigationHotKeys() as? [[String: Any]])?.first(where: { $0["id"] as? Int == (forward ? 81 : 79) }),
    binding["status"] as? Int == 0, binding["enabled"] as? Bool == true,
    binding["keyCode"] as? UInt16 != nil, binding["flags"] as? UInt64 != nil else {
    throw TrialError("An enabled native previous/next Desktop shortcut is required")
  }
  return binding
}

func enterAdjacent(id: UInt64, display: String, forward: Bool) throws -> [String: Any] {
  let before = try Creation.decode(nativeCensus())
  guard before.count == 1, before[0].identifier == display,
    let currentIndex = before[0].spaces.firstIndex(where: { $0.id == before[0].currentSpaceID }),
    let targetIndex = before[0].spaces.firstIndex(where: { $0.id == id }),
    targetIndex == currentIndex + (forward ? 1 : -1),
    try missionControlInventory(inspectOnly: true)["visible"] as? Bool == false else {
    throw TrialError("Native entry requires the exact adjacent destination and a closed overview")
  }
  let binding = try adjacentBinding(forward: forward), started = ProcessInfo.processInfo.systemUptime
  let dispatchedAt = Date().timeIntervalSince1970 * 1000
  for down in [true, false] {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: binding["keyCode"] as! UInt16, keyDown: down)!
    event.flags = down ? CGEventFlags(rawValue: binding["flags"] as! UInt64) : []
    event.post(tap: .cghidEventTap)
  }
  var current = before
  repeat {
    RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    current = try Creation.decode(nativeCensus())
    if current.count == 1, current[0].currentSpaceID == id { break }
  } while ProcessInfo.processInfo.systemUptime - started < 3
  return ["binding": binding, "expectedID": String(id), "dispatchedAtMillisecondsSince1970": dispatchedAt,
    "dispatchUptime": started,
    "verified": current.count == 1 && current[0].identifier == display && current[0].currentSpaceID == id && current[0].spaces == before[0].spaces,
    "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000, "after": try nativeCensus()]
}

func refreshVerified(_ refresh: [String: Any], count: Int) -> Bool {
  let dock = NativeBridge.dockSpaceCount() as! [String: Any]
  return refresh["mutationDispatched"] as? Bool == true && refresh["modeAndBoundsUnchanged"] as? Bool == true &&
    refresh["mirrorGroupUnchanged"] as? Bool == true && refresh["onlineDisplaysUnchanged"] as? Bool == true &&
    refresh["setupUIObserved"] as? Bool == false && refresh["setupQueryComplete"] as? Bool == true &&
    dock["status"] as? Int == 0 && dock["count"] as? Int == count
}

func observeDockRegistration(expected: [[String: Any]]) throws -> [String: Any] {
  let count = try Creation.decode(expected).flatMap(\.spaces).count
  let observation = try DockRegistration.observe(expectedCount: count, read: {
    guard NSArray(array: try nativeCensus()).isEqual(to: expected) else {
      throw TrialError("Space identity, order, or current Desktop changed while waiting for Dock")
    }
    let dock = NativeBridge.dockSpaceCount() as! [String: Any]
    guard dock["status"] as? Int == 0, let count = dock["count"] as? Int else {
      throw TrialError("Dock's Desktop count is unavailable; no refresh was attempted")
    }
    return count
  }, now: { ProcessInfo.processInfo.systemUptime }, pause: {
    RunLoop.current.run(until: Date().addingTimeInterval(0.025))
  })
  return ["confirmed": observation.confirmed, "milliseconds": observation.milliseconds,
    "counts": observation.counts, "expectedCount": count, "mutationDispatched": false]
}

func runReady(path: String, display requestedDisplay: String?, enter: Bool, testTyping: Bool) throws -> [String: Any] {
  let lock = try MutationLock()
  return try withExtendedLifetime(lock) {
    let before = try nativeCensus(), original = try Creation.decode(before)
    let display = try Creation.targetDisplay(requested: requestedDisplay, screenCount: NSScreen.screens.count, census: original)
    let dock = NativeBridge.dockSpaceCount() as! [String: Any]
    guard original.count == 1, original[0].identifier == display, original[0].spaces.allSatisfy({ $0.rawType == 0 }),
      dock["status"] as? Int == 0, dock["count"] as? Int == original[0].spaces.count,
      try missionControlInventory(inspectOnly: true)["visible"] as? Bool == false else {
      throw TrialError("Creation requires one display, no fullscreen neighbors, a closed overview, and matching Dock/WindowServer counts")
    }
    if enter { _ = try adjacentBinding(forward: true) }
    let started = ProcessInfo.processInfo.systemUptime
    let created = try runCreate(path: path, display: display, engineOwnsLock: true)
    guard created["status"] as? String == "managed-type0-confirmed", let idString = created["createdID"] as? String,
      let id = UInt64(idString) else { return created }
    let journal = try Journal(path: path, create: false)
    var setupObservation: DisplaySetupObservation?
    var report = created
    report["status"] = "created-refresh-unconfirmed"
    do {
      let rawCreated = try nativeCensus(), afterCreate = try Creation.decode(rawCreated)
      guard afterCreate.count == 1, afterCreate[0].currentSpaceID == original[0].currentSpaceID,
        afterCreate[0].spaces.filter({ $0.id != id }) == original[0].spaces,
        let homeIndex = afterCreate[0].spaces.firstIndex(where: { $0.id == original[0].currentSpaceID }) else {
        throw TrialError("Creation changed the original topology; inspect before proceeding")
      }
      try journal.write("ready-intent.json", ["createdID": idString, "before": rawCreated,
        "placementIndex": homeIndex + 1, "enter": enter, "testTyping": testTyping, "mayApplyAfterInterruption": true])
      if afterCreate[0].spaces.firstIndex(where: { $0.id == id }) != homeIndex + 1 {
        let placement = NativeBridge.placeSpace(id, display: display, index: UInt32(homeIndex + 1)) as! [String: Any]
        report["placement"] = placement
        try journal.write("ready-placement.json", placement)
      }
      // A void WMBridge dispatch can return before the census reflects its move.
      // Poll the original attempt; never send another move while it is pending.
      let placementStarted = ProcessInfo.processInfo.systemUptime
      var placed = try Creation.decode(nativeCensus())
      while placed.count == 1, placed[0].spaces.firstIndex(where: { $0.id == id }) != homeIndex + 1,
        ProcessInfo.processInfo.systemUptime - placementStarted < 1 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        placed = try Creation.decode(nativeCensus())
      }
      report["placementConfirmationMilliseconds"] = (ProcessInfo.processInfo.systemUptime - placementStarted) * 1000
      guard placed.count == 1, placed[0].identifier == display, placed[0].currentSpaceID == original[0].currentSpaceID,
        placed[0].spaces.filter({ $0.id != id }) == original[0].spaces,
        placed[0].spaces.firstIndex(where: { $0.id == id }) == homeIndex + 1 else { throw TrialError("Adjacent placement was not confirmed") }
      let rawPlaced = try nativeCensus()
      guard try Creation.decode(rawPlaced) == placed else { throw TrialError("Topology changed before Dock registration") }
      let registration = try observeDockRegistration(expected: rawPlaced)
      report["nativeRegistration"] = registration
      try journal.write("ready-registration.json", registration)
      if registration["confirmed"] as? Bool == true {
        report["registrationMethod"] = "native"
        report["refresh"] = ["mutationDispatched": false, "reason": "Dock registered the Desktop without a display refresh"]
      } else {
        let setup = DisplaySetupObservation()
        setupObservation = setup
        let refresh = refreshDisplays(mode: "refresh-virtual-pulse", setupObservation: setup, ready: {
          guard let fresh = try? Creation.decode(nativeCensus()), fresh == placed else { return false }
          let count = NativeBridge.dockSpaceCount() as! [String: Any]
          return count["status"] as? Int == 0 && count["count"] as? Int == placed[0].spaces.count
        })
        report["registrationMethod"] = "virtual-display"
        report["refresh"] = refresh
        try journal.write("ready-refresh.json", refresh)
        guard refreshVerified(refresh, count: placed[0].spaces.count) else {
          throw TrialError("Dock refresh or display restoration was not confirmed")
        }
      }
      let ready = try Creation.decode(nativeCensus())
      guard ready == placed else { throw TrialError("Topology changed during Dock registration") }
      report["status"] = "dock-registration-confirmed"
      report["dockSpaceCount"] = NativeBridge.dockSpaceCount()
      report["creationToReadyMilliseconds"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
      let initial = try journal.read("intent.json")["observation"] as? [String: Any] ?? [:]
      let observation = NativeBridge.observation() as! [String: Any]
      report["observationReady"] = observation
      report["pointerUnchangedThroughRefresh"] = NSDictionary(dictionary: initial["pointer"] as? [String: Any] ?? [:]).isEqual(to: observation["pointer"] as? [String: Any] ?? [:])
      report["focusUnchangedThroughRefresh"] = initial["focusKnown"] as? Bool == true && observation["focusKnown"] as? Bool == true &&
        initial["frontPID"] as? Int == observation["frontPID"] as? Int && initial["focusedWindow"] as? Int == observation["focusedWindow"] as? Int
      let oldWindows = initial["windows"] as? [String: [String: Any]] ?? [:], newWindows = observation["windows"] as? [String: [String: Any]] ?? [:]
      let changes = oldWindows.filter { $0.value["layer"] as? Int == 0 }.compactMap { key, old -> [String: Any]? in
        guard let new = newWindows[key] else { return ["id": key, "change": "absent", "before": old] }
        guard new["pid"] as? Int == old["pid"] as? Int,
          let oldBounds = old["bounds"] as? [String: Any], let newBounds = new["bounds"] as? [String: Any],
          NSDictionary(dictionary: oldBounds).isEqual(to: newBounds) else { return ["id": key, "change": "identity-or-bounds", "before": old, "after": new] }
        return nil
      }
      report["originalAppWindowChanges"] = changes
      report["originalAppWindowBoundsUnchanged"] = changes.isEmpty
      if enter {
        try journal.write("ready-entry-intent.json", ["expectedID": idString, "before": try nativeCensus()])
        let entry = try enterAdjacent(id: id, display: display, forward: true)
        report["entry"] = entry
        if let dispatchUptime = entry["dispatchUptime"] as? Double {
          report["creationToEntryDispatchMilliseconds"] = (dispatchUptime - started) * 1000
        }
        guard entry["verified"] as? Bool == true else { throw TrialError("Native adjacent entry was not verified") }
        report["status"] = "native-entry-confirmed"
        report["creationToEntryMilliseconds"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        if testTyping { report["typing"] = try typingFixture(directory: journal.directory, spaceID: id) }
      }
    } catch { report["error"] = error.localizedDescription }
    // Keep the full observation window, overlapping it with native entry and
    // typing instead of delaying the user's switch by a fixed second.
    if let setupObservation {
      let setup = setupObservation.finish()
      report["setupObservation"] = setup
      if setup["setupUIObserved"] as? Bool == true || setup["queryComplete"] as? Bool != true {
        report["error"] = "Display setup UI appeared or could not be observed; inspect the retained Desktop"
      }
    }
    report["creationToCompletionMilliseconds"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
    report["after"] = try nativeCensus()
    try journal.write("ready-result.json", report)
    return report
  }
}

func runReadyCleanup(path: String) throws -> [String: Any] {
  let lock = try MutationLock()
  return try withExtendedLifetime(lock) {
    var report = try runCleanup(path: path, engineOwnsLock: true)
    guard report["status"] as? String == "removed" else { return report }
    let journal = try Journal(path: path, create: false)
    let before = try nativeCensus()
    let registration = try observeDockRegistration(expected: before)
    report["nativeRegistration"] = registration
    if registration["confirmed"] as? Bool == true {
      report["registrationMethod"] = "native"
      report["refresh"] = ["mutationDispatched": false, "reason": "Dock reconciled removal without a display refresh"]
      report["dockSpaceCount"] = NativeBridge.dockSpaceCount()
      report["after"] = try nativeCensus()
      try journal.write("cleanup-ready-result.json", report)
      return report
    }
    try journal.write("cleanup-refresh-intent.json", ["before": before, "mayApplyAfterInterruption": true])
    let refresh = refreshDisplays(mode: "refresh-virtual-pulse")
    report["registrationMethod"] = "virtual-display"
    report["refresh"] = refresh
    let after = try nativeCensus()
    report["dockSpaceCount"] = NativeBridge.dockSpaceCount()
    report["after"] = after
    if try Creation.decode(after) != Creation.decode(before) || !refreshVerified(refresh, count: (try Creation.decode(after)).flatMap({ $0.spaces }).count) {
      report["status"] = "removed-refresh-unconfirmed"
    }
    try journal.write("cleanup-ready-result.json", report)
    return report
  }
}
