// Bounded follow-up hypotheses on a journal-owned Space. Placement and activation
// are independent trials; the original order/current Space are recovery authority.
import AppKit
import NativeBridge
import Trial

private final class DisplayRefreshEvents {
  private let lock = NSLock()
  private var values: [[String: Any]] = []
  func append(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
    lock.lock(); defer { lock.unlock() }
    values.append(["displayID": display, "flags": flags.rawValue])
  }
  func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return values }
}

// Reapply the selected mode on the sole screen (optionally a mirror source). No
// alternate resolution, position, mirroring setting, or permanent setting is used.
private func refreshUnchangedDisplay(empty: Bool, permitMirror: Bool) -> [String: Any] {
  guard NSScreen.screens.count == 1,
    let number = NSScreen.screens[0].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
    (empty || permitMirror || CGDisplayIsInMirrorSet(number.uint32Value) == 0),
    let mode = CGDisplayCopyDisplayMode(number.uint32Value) else {
    return ["mutationDispatched": false, "error": "A sole non-mirrored display with a readable mode is required"]
  }
  let display = number.uint32Value, bounds = CGDisplayBounds(number.uint32Value)
  var online = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
  guard CGGetOnlineDisplayList(32, &online, &count) == .success else { return ["mutationDispatched": false, "error": "Display query failed"] }
  let mirrors = online.prefix(Int(count)).map { ["id": $0, "mirrors": CGDisplayMirrorsDisplay($0), "modeID": CGDisplayCopyDisplayMode($0)?.ioDisplayModeID ?? 0] }
  guard !permitMirror || (CGDisplayMirrorsDisplay(display) == 0 && online.prefix(Int(count)).allSatisfy {
    $0 == display || CGDisplayMirrorsDisplay($0) == display
  }) else { return ["mutationDispatched": false, "error": "Only a single mirror group with this display as its source is supported"] }
  let events = DisplayRefreshEvents()
  let context = Unmanaged.passUnretained(events).toOpaque()
  let callback: CGDisplayReconfigurationCallBack = { display, flags, context in
    guard let context else { return }
    Unmanaged<DisplayRefreshEvents>.fromOpaque(context).takeUnretainedValue().append(display, flags)
  }
  let registration = CGDisplayRegisterReconfigurationCallback(callback, context)
  guard registration == .success else { return ["mutationDispatched": false, "error": "Could not observe display refresh"] }
  defer { CGDisplayRemoveReconfigurationCallback(callback, context); withExtendedLifetime(events) {} }
  var config: CGDisplayConfigRef?
  let begin = CGBeginDisplayConfiguration(&config)
  guard begin == .success, let config else { return ["mutationDispatched": false, "beginError": begin.rawValue] }
  let configure = empty ? CGError.success : CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
  guard configure == .success else {
    CGCancelDisplayConfiguration(config)
    return ["mutationDispatched": false, "configureError": configure.rawValue]
  }
  let complete = CGCompleteDisplayConfiguration(config, .forSession)
  RunLoop.current.run(until: Date().addingTimeInterval(0.4))
  let after = CGDisplayCopyDisplayMode(display)
  let mirrorsAfter = online.prefix(Int(count)).map { ["id": $0, "mirrors": CGDisplayMirrorsDisplay($0), "modeID": CGDisplayCopyDisplayMode($0)?.ioDisplayModeID ?? 0] }
  return ["mutationDispatched": true, "completeError": complete.rawValue, "displayID": display,
    "mirrorGroupBefore": mirrors, "mirrorGroupAfter": mirrorsAfter, "mirrorGroupUnchanged": NSArray(array: mirrors).isEqual(to: mirrorsAfter),
    "emptyTransaction": empty,
    "modeID": mode.ioDisplayModeID, "width": mode.width, "height": mode.height,
    "pixelWidth": mode.pixelWidth, "pixelHeight": mode.pixelHeight,
    "bounds": NSStringFromRect(bounds), "callbacks": events.snapshot(),
    "modeAndBoundsUnchanged": after.map { CFEqual(mode, $0) && CGDisplayBounds(display) == bounds } ?? false]
}

func missionControlInventory(select index: Int? = nil, inspectOnly: Bool = false) throws -> [String: Any] {
  guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    throw TrialError("Mission Control inventory requires existing Accessibility trust and Dock")
  }
  func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
  }
  func elements() -> [AXUIElement] {
    var queue = [(AXUIElementCreateApplication(dock.processIdentifier), 0)], result: [AXUIElement] = [], index = 0
    while index < queue.count && index < 2_000 {
      let (item, depth) = queue[index]; index += 1; result.append(item)
      if depth < 8, let children = attribute(item, kAXChildrenAttribute) as? [AXUIElement] {
        queue.append(contentsOf: children.map { ($0, depth + 1) })
      }
    }
    return result
  }
  func visible() -> Bool { elements().contains { attribute($0, "AXIdentifier") as? String == "mc" } }
  if inspectOnly { return ["visible": visible()] }
  guard !visible() else { throw TrialError("Close Mission Control before a bounded inventory trial") }
  let launch = commandOutput("/usr/bin/open", ["-a", "Mission Control"])
  RunLoop.current.run(until: Date().addingTimeInterval(0.6))
  guard visible() else { throw TrialError("Mission Control did not expose its AX hierarchy: \(launch)") }
  let lists = elements().filter { attribute($0, "AXIdentifier") as? String == "mc.spaces.list" }
  let desktops = lists.map { list -> [[String: Any]] in
    (attribute(list, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { element in
      ["title": attribute(element, kAXTitleAttribute) as? String ?? "",
       "description": attribute(element, kAXDescriptionAttribute) as? String ?? "",
       "identifier": attribute(element, "AXIdentifier") as? String ?? ""]
    }
  }
  var selectionError: AXError?
  if let index, lists.count == 1,
    let buttons = attribute(lists[0], kAXChildrenAttribute) as? [AXUIElement], buttons.indices.contains(index) {
    selectionError = AXUIElementPerformAction(buttons[index], kAXPressAction as CFString)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
  }
  // Escape is posted only while the overview this function opened is present.
  if visible() {
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
  }
  RunLoop.current.run(until: Date().addingTimeInterval(0.35))
  var result: [String: Any] = ["lists": desktops, "thumbnailCount": desktops.reduce(0) { $0 + $1.count }, "closed": !visible()]
  if let index { result["selectedIndex"] = index; result["selectionAXError"] = selectionError?.rawValue ?? AXError.illegalArgument.rawValue }
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
    guard ["place-current", "reorder-roundtrip", "activate-roundtrip", "native-adjacent-roundtrip", "native-select-roundtrip", "refresh-display", "refresh-empty", "refresh-mirror-mode"].contains(mode) else { throw TrialError("Unknown follow-up mode") }
    let home = topology[0].currentSpaceID, ids = topology[0].spaces.map(\.id)
    guard mode != "native-adjacent-roundtrip" || ids.firstIndex(of: home).map({ $0 + 1 == index }) == true else {
      throw TrialError("The owned Space must be immediately right of the current Desktop")
    }
    let trial = try Journal(path: outputPath, create: true)
    var report: [String: Any] = ["mode": mode, "ownedID": stringID, "spaceUUID": uuid, "before": before,
      "home": String(home), "originalIndex": index, "date": ISO8601DateFormatter().string(from: Date())]
    if mode.hasPrefix("native-") {
      // Do not open/close an overview immediately before testing a shortcut;
      // its exit animation can suppress the very input under test.
      let count = NativeBridge.dockSpaceCount() as! [String: Any]
      guard count["status"] as? Int == 0, count["count"] as? Int == ids.count,
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
    if mode.hasPrefix("refresh-") { sent = refreshUnchangedDisplay(empty: mode == "refresh-empty", permitMirror: mode == "refresh-mirror-mode") }
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
      sent = try missionControlInventory(select: index).merging(["mutationDispatched": true]) { _, new in new }
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
      report["observationAfterDispatch"] = NativeBridge.observation()
      if isActivation {
        do { report["typing"] = try typingFixture(directory: trial.directory, spaceID: id) }
        catch { report["typingError"] = error.localizedDescription }
      }
      report["missionControlAfter"] = try missionControlInventory()
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
