// Bounded follow-up hypotheses on a journal-owned Space. Placement and activation
// are independent trials; the original order/current Space are recovery authority.
import AppKit
import NativeBridge
import Trial

func missionControlInventory(select index: Int? = nil, inspectOnly: Bool = false) throws -> [String: Any] {
  guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    throw TrialError("Mission Control inventory requires existing Accessibility trust and Dock")
  }
  let root = AXUIElementCreateApplication(dock.processIdentifier)
  func attribute(_ element: AXUIElement, _ name: String, required: Bool = false) throws -> Any? {
    try dockAttribute(element, name, required: required)
  }
  func elements() throws -> [AXUIElement] {
    try dockHierarchy(root).map(\.element)
  }
  func visible() throws -> Bool {
    for item in try elements() {
      if let value = try attribute(item, "AXIdentifier") {
        guard let identifier = value as? String else { throw TrialError("Dock returned a non-string AXIdentifier") }
        if identifier == "mc" { return true }
      }
    }
    return false
  }
  if inspectOnly { return ["visible": try visible()] }
  guard try !visible() else { throw TrialError("Close Mission Control before a bounded inventory trial") }
  let launch = commandOutput("/usr/bin/open", ["-a", "Mission Control"])
  RunLoop.current.run(until: Date().addingTimeInterval(0.6))
  guard try visible() else { throw TrialError("Mission Control did not expose its AX hierarchy: \(launch)") }
  let hierarchy = try elements()
  let lists = try hierarchy.filter { try attribute($0, "AXIdentifier") as? String == "mc.spaces.list" }
  let identifiers = try hierarchy.map { element -> [String: Any] in
    ["role": try attribute(element, kAXRoleAttribute, required: true) as? String ?? "",
     "identifier": try attribute(element, "AXIdentifier") as? String ?? "",
     "children": (try attribute(element, kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0]
  }
  let desktops = try lists.map { list -> [[String: Any]] in
    try (attribute(list, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { element in
      ["title": try attribute(element, kAXTitleAttribute) as? String ?? "",
       "description": try attribute(element, kAXDescriptionAttribute) as? String ?? "",
       "identifier": try attribute(element, "AXIdentifier") as? String ?? ""]
    }
  }
  var selectionError: AXError?
  if let index, lists.count == 1,
    let buttons = try attribute(lists[0], kAXChildrenAttribute) as? [AXUIElement], buttons.indices.contains(index) {
    selectionError = AXUIElementPerformAction(buttons[index], kAXPressAction as CFString)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
  }
  // Escape is posted only while the overview this function opened is present.
  if try visible() {
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
  }
  RunLoop.current.run(until: Date().addingTimeInterval(0.35))
  var result: [String: Any] = ["lists": desktops,
    "thumbnailCount": lists.count == NSScreen.screens.count ? desktops.reduce(0) { $0 + $1.count } as Any : NSNull(),
    "complete": lists.count == NSScreen.screens.count, "hierarchy": identifiers, "closed": try !visible()]
  if let index {
    result["selectedIndex"] = index
    result["selectionDispatched"] = selectionError != nil
    result["selectionAXError"] = selectionError.map { $0.rawValue as Any } ?? NSNull()
  }
  return result
}

func runFollowup(creationPath: String, outputPath: String, mode: String) throws -> [String: Any] {
  let lock = try MutationLock()
  return try withExtendedLifetime(lock) {
    let creation = try Journal(path: creationPath, create: false)
    let intent = try creation.read("intent.json"), result = try creation.read("result.json"), dispatch = try creation.read("dispatch.json")
    guard result["status"] as? String == "managed-type0-confirmed",
      let stringID = result["createdID"] as? String, let id = UInt64(stringID), id > 0,
      dispatch["createdID"] as? String == stringID, let display = intent["display"] as? String
    else { throw TrialError("Follow-up requires an unambiguously journal-owned ID") }
    let original = try Creation.decode(intent["before"] as? [[String: Any]] ?? [])
    guard !original.contains(where: { $0.spaces.contains(where: { $0.id == id }) }) else { throw TrialError("Follow-up cannot target an original Desktop") }
    _ = try runCreate(path: "", display: display, preflightOnly: true, engineOwnsLock: true)
    let before = try nativeCensus(), topology = try Creation.decode(before)
    let records = before[0]["Spaces"] as? [[String: Any]] ?? []
    let saved = (result["after"] as? [[String: Any]] ?? []).flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }
      .first { ($0["id64"] as? NSNumber)?.uint64Value == id }
    guard topology[0].spaces.allSatisfy({ $0.rawType == 0 }), topology[0].currentSpaceID != id,
      let index = topology[0].spaces.firstIndex(where: { $0.id == id }),
      let uuid = saved?["uuid"] as? String, !uuid.isEmpty,
      records[index]["uuid"] as? String == uuid else { throw TrialError("Owned Space changed UUID/type/display, is active, or has fullscreen neighbors") }
    guard ["place-current", "reorder-roundtrip", "activate-roundtrip", "native-adjacent-roundtrip", "native-select-roundtrip", "refresh-display", "refresh-empty", "refresh-mirror-mode", "refresh-detect", "refresh-virtual", "refresh-virtual-active", "refresh-virtual-reference", "refresh-virtual-pulse"].contains(mode) else { throw TrialError("Unknown follow-up mode") }
    let home = topology[0].currentSpaceID, ids = topology[0].spaces.map(\.id)
    guard mode != "native-adjacent-roundtrip" || ids.firstIndex(of: home).map({ $0 + 1 == index }) == true else {
      throw TrialError("The owned Space must be immediately right of the current Desktop")
    }
    let trial = try Journal(path: outputPath, create: true)
    var report: [String: Any] = ["mode": mode, "ownedID": stringID, "spaceUUID": uuid, "before": before,
      "home": String(home), "originalIndex": index, "date": ISO8601DateFormatter().string(from: Date())]
    if mode.hasPrefix("native-") || mode == "refresh-detect" || mode.hasPrefix("refresh-virtual") {
      // Do not open/close an overview immediately before testing a shortcut;
      // its exit animation can suppress the very input under test.
      let count = NativeBridge.dockSpaceCount() as! [String: Any]
      guard count["status"] as? Int == 0, (mode.hasPrefix("refresh-") || count["count"] as? Int == ids.count),
        try missionControlInventory(inspectOnly: true)["visible"] as? Bool == false else {
        throw TrialError("Native entry requires a closed overview and agreement between Dock and WindowServer counts")
      }
      report["dockCountBefore"] = count
    } else { report["missionControlBefore"] = try missionControlInventory() }
    guard try Creation.decode(nativeCensus()) == topology else { throw TrialError("Topology changed during Mission Control inventory") }
    let targetIndex = mode == "reorder-roundtrip" ? (index == 0 ? 1 : index - 1) : index
    try trial.write("intent.json", report.merging(["targetIndex": targetIndex, "creationPath": creationPath, "mayApplyAfterInterruption": true]) { _, new in new })
    let isActivation = ["activate-roundtrip", "native-adjacent-roundtrip", "native-select-roundtrip"].contains(mode)
    let sent: [String: Any]
    if mode.hasPrefix("refresh-") { sent = refreshDisplays(mode: mode) }
    else if mode == "native-adjacent-roundtrip" {
      guard let binding = (NativeBridge.navigationHotKeys() as? [[String: Any]])?.first(where: { $0["id"] as? Int == 81 }),
        binding["status"] as? Int == 0, binding["enabled"] as? Bool == true,
        let key = binding["keyCode"] as? UInt16, let flags = binding["flags"] as? UInt64 else {
        throw TrialError("The native next-Desktop shortcut must have an enabled, readable binding")
      }
      for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
        event.flags = down ? CGEventFlags(rawValue: flags) : []; event.post(tap: .cghidEventTap)
      }
      sent = ["mutationDispatched": true, "input": "Native next-Desktop shortcut", "binding": binding]
    }
    else if mode == "native-select-roundtrip" {
      var selection = try missionControlInventory(select: index)
      selection["mutationDispatched"] = selection["selectionDispatched"] as? Bool == true
      sent = selection
    }
    else if isActivation { sent = NativeBridge.activateSpace(id, display: display, hiding: ids.filter { $0 != id }.map { NSNumber(value: $0) }) as! [String: Any] }
    else { sent = NativeBridge.placeSpace(id, display: display, index: UInt32(targetIndex)) as! [String: Any] }
    report["dispatch"] = sent
    do {
      try trial.write("dispatch.json", sent)
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      if mode == "native-adjacent-roundtrip" {
        let deadline = ProcessInfo.processInfo.systemUptime + 2.6
        while try Creation.decode(nativeCensus())[0].currentSpaceID != id,
          ProcessInfo.processInfo.systemUptime < deadline {
          RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
      }
      report["afterDispatch"] = try nativeCensus()
      report["dockCountAfterDispatch"] = NativeBridge.dockSpaceCount()
      report["observationAfterDispatch"] = NativeBridge.observation()
      if isActivation && sent["mutationDispatched"] as? Bool == true {
        do { report["typing"] = try typingFixture(directory: trial.directory, spaceID: id) }
        catch { report["typingError"] = error.localizedDescription }
      }
      report["missionControlAfter"] = try missionControlInventory(inspectOnly: ["refresh-virtual-reference", "refresh-virtual-pulse"].contains(mode))
      report["afterMissionControl"] = try nativeCensus()
    } catch { report["observationError"] = error.localizedDescription }
    if sent["mutationDispatched"] as? Bool == true && (isActivation || targetIndex != index) {
      let fresh = try nativeCensus()
      let freshRecords = fresh.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }
      let identity: ([[String: Any]]) -> [String: String] = { Dictionary(uniqueKeysWithValues: $0.map {
        ((($0["id64"] as? NSNumber)?.stringValue ?? ""), ($0["uuid"] as? String ?? ""))
      }) }
      guard fresh.count == 1, fresh[0]["Display Identifier"] as? String == display,
        identity(freshRecords) == identity(records) else { throw TrialError("Topology identity changed; inspect follow-up journal before restoring") }
      try trial.write("restore-intent.json", ["home": String(home), "ownedID": stringID, "originalIndex": index, "before": fresh])
      if mode.hasPrefix("native-") {
        // Restore through Dock after native entry: changing only WindowServer's
        // current ID can leave Dock's own current ManagedSpace object stale.
        report["restoreDispatch"] = try missionControlInventory(select: ids.firstIndex(of: home)!)
      } else {
        report["restoreDispatch"] = isActivation
          ? NativeBridge.activateSpace(home, display: display, hiding: ids.filter { $0 != home }.map { NSNumber(value: $0) })
          : NativeBridge.placeSpace(id, display: display, index: UInt32(index))
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
    report["afterRestore"] = try nativeCensus()
    report["topologyRestored"] = try Creation.decode(nativeCensus()) == topology
    report["observationAfterRestore"] = NativeBridge.observation()
    try trial.write("result.json", report)
    return report
  }
}
