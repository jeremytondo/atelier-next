// Read Dock's exposed Accessibility actions without opening Mission Control or
// invoking an action. Query errors and traversal limits keep absence inconclusive.
import AppKit
import NativeBridge
import Trial

func dockAttribute(_ element: AXUIElement, _ name: String, required: Bool = false) throws -> Any? {
  var value: CFTypeRef?
  let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
  if status == .success {
    guard !required || value != nil else { throw TrialError("Dock query \(name) returned no required value") }
    return value
  }
  if !required && [AXError.attributeUnsupported, .noValue].contains(status) { return nil }
  throw TrialError("Dock query \(name) failed: \(status.rawValue)")
}

func dockHierarchy(_ root: AXUIElement) throws -> [(element: AXUIElement, depth: Int)] {
  guard AXUIElementSetMessagingTimeout(root, 0.1) == .success,
    try dockAttribute(root, kAXRoleAttribute, required: true) as? String == kAXApplicationRole else {
    throw TrialError("Cannot inspect a bounded Dock application hierarchy")
  }
  let started = ProcessInfo.processInfo.systemUptime
  var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)], index = 0
  while index < queue.count {
    guard ProcessInfo.processInfo.systemUptime - started < 2 else {
      throw TrialError("Dock hierarchy inspection reached its deadline")
    }
    let (item, depth) = queue[index]; index += 1
    if let value = try dockAttribute(item, kAXChildrenAttribute, required: depth == 0) {
      guard let children = value as? [AXUIElement], depth < 8 || children.isEmpty,
        depth != 0 || !children.isEmpty else {
        throw TrialError("Dock hierarchy is incomplete or has unexpected children")
      }
      for child in children where !queue.contains(where: { CFEqual($0.element, child) }) {
        guard queue.count < 2_000 else { throw TrialError("Dock hierarchy exceeded its node limit") }
        queue.append((child, depth + 1))
      }
    }
  }
  return queue
}

func inspectDock() throws -> [String: Any] {
  guard AXIsProcessTrusted() else { throw TrialError("Dock inspection requires existing Accessibility trust") }
  let docks = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
  guard docks.count == 1 else { throw TrialError("Dock inspection requires exactly one Dock process") }
  let before = try nativeCensus(), countBefore = NativeBridge.dockSpaceCount()
  let root = AXUIElementCreateApplication(docks[0].processIdentifier)
  let started = ProcessInfo.processInfo.systemUptime
  var errors: [[String: Any]] = [], rows: [[String: Any]] = []
  let hierarchy = try dockHierarchy(root)
  for (index, node) in hierarchy.enumerated() {
    guard ProcessInfo.processInfo.systemUptime - started < 2 else {
      errors.append(["query": "metadata", "error": "Inspection deadline reached"]); break
    }
    let (element, depth) = node
    var row: [String: Any] = ["index": index, "depth": depth]
    for name in [kAXRoleAttribute, kAXSubroleAttribute, "AXIdentifier"] {
      do {
        if let value = try dockAttribute(element, name, required: name == kAXRoleAttribute) as? String { row[name] = value }
      } catch { errors.append(["node": index, "query": name, "error": error.localizedDescription]) }
    }
    var names: CFArray?
    let actionStatus = AXUIElementCopyActionNames(element, &names)
    row["actions"] = names as? [String] ?? []
    row["actionsStatus"] = actionStatus.rawValue
    if actionStatus != .success { errors.append(["node": index, "query": "actions", "status": actionStatus.rawValue]) }
    names = nil
    let parameterStatus = AXUIElementCopyParameterizedAttributeNames(element, &names)
    row["parameterizedAttributes"] = names as? [String] ?? []
    row["parameterizedAttributesStatus"] = parameterStatus.rawValue
    if parameterStatus != .success { errors.append(["node": index, "query": "parameterizedAttributes", "status": parameterStatus.rawValue]) }
    rows.append(row)
  }
  let after = try nativeCensus(), countAfter = NativeBridge.dockSpaceCount()
  return ["date": ISO8601DateFormatter().string(from: Date()), "mutationDispatched": false,
    "dockPID": docks[0].processIdentifier, "complete": errors.isEmpty,
    "hierarchyComplete": true, "hierarchyCount": hierarchy.count, "errors": errors, "elements": rows,
    "missionControlFound": rows.contains { $0["AXIdentifier"] as? String == "mc" },
    "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
    "censusBefore": before, "censusAfter": after,
    "censusUnchanged": NSArray(array: before).isEqual(to: after),
    "dockCountBefore": countBefore, "dockCountAfter": countAfter,
    "scope": "Currently exposed AXChildren hierarchy and action names; no actions or parameterized reads invoked"]
}
