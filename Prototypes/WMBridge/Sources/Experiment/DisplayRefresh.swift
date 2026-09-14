// Bounded display-callback trials. Only a process-owned virtual display may gain
// a new mode; original resolutions and mirror configuration are verified.
import AppKit
import NativeBridge

private final class DisplayRefreshEvents {
  private let lock = NSLock()
  private var values: [[String: Any]] = []
  func append(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
    lock.lock(); defer { lock.unlock() }
    values.append(["displayID": display, "flags": flags.rawValue, "uptime": ProcessInfo.processInfo.systemUptime])
  }
  func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return values }
}

// Compare no-op configurations, hardware detection, and temporary virtual
// displays. The ready flow uses immediate release to avoid display setup UI;
// original display modes, positions, and mirror settings are never changed.
func refreshDisplays(mode refreshMode: String) -> [String: Any] {
  let started = ProcessInfo.processInfo.systemUptime
  func setupWindows() -> [UInt32] {
    (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap {
      guard let pid = $0[kCGWindowOwnerPID as String] as? Int32,
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.controlcenter.helper" else { return nil }
      return $0[kCGWindowNumber as String] as? UInt32
    }
  }
  let initialSetupWindows = Set(setupWindows())
  var newSetupWindows = Set<UInt32>()
  let empty = refreshMode == "refresh-empty", detect = refreshMode == "refresh-detect"
  let pulse = refreshMode == "refresh-virtual-pulse"
  let virtual = refreshMode.hasPrefix("refresh-virtual"), configureVirtual = refreshMode != "refresh-virtual"
  let permitMirror = refreshMode != "refresh-display"
  guard ["refresh-display", "refresh-empty", "refresh-mirror-mode", "refresh-detect", "refresh-virtual", "refresh-virtual-active", "refresh-virtual-reference", "refresh-virtual-pulse"].contains(refreshMode) else {
    return ["mutationDispatched": false, "error": "Unknown display refresh mode"]
  }
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
  var detection: [String: Any] = [:]
  var complete = CGError.success
  if detect || virtual {
    detection = (virtual ? NativeBridge.startVirtualDisplay(configureVirtual, reference: refreshMode == "refresh-virtual-reference") : NativeBridge.detectDisplays()) as! [String: Any]
  } else {
    var config: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&config)
    guard begin == .success, let config else { return ["mutationDispatched": false, "beginError": begin.rawValue] }
    let configure = empty ? CGError.success : CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
    guard configure == .success else {
      CGCancelDisplayConfiguration(config)
      return ["mutationDispatched": false, "configureError": configure.rawValue]
    }
    complete = CGCompleteDisplayConfiguration(config, .forSession)
  }
  if !pulse { RunLoop.current.run(until: Date().addingTimeInterval(detect || virtual ? 2 : 0.4)) }
  if virtual {
    detection["censusWhileOwned"] = NativeBridge.census()
    detection["screensWhileOwned"] = NSScreen.screens.map { ["name": $0.localizedName, "frame": NSStringFromRect($0.frame)] }
    if let owned = detection["displayID"] as? UInt32 {
      detection["ownedOnlineDuringTrial"] = CGDisplayIsOnline(owned)
      detection["ownedActiveDuringTrial"] = CGDisplayIsActive(owned)
    }
    NativeBridge.stopVirtualDisplay()
    let deadline = ProcessInfo.processInfo.systemUptime + (pulse ? 1 : 2)
    repeat {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      newSetupWindows.formUnion(Set(setupWindows()).subtracting(initialSetupWindows))
    } while ProcessInfo.processInfo.systemUptime < deadline
    detection["ownedDisplayOnlineAfterRelease"] = (detection["displayID"] as? UInt32).map { CGDisplayIsOnline($0) } ?? 0
  }
  var onlineAfter = [CGDirectDisplayID](repeating: 0, count: 32), countAfter: UInt32 = 0
  let onlineAfterError = CGGetOnlineDisplayList(32, &onlineAfter, &countAfter)
  let after = CGDisplayCopyDisplayMode(display)
  let mirrorsAfter = online.prefix(Int(count)).map { ["id": $0, "mirrors": CGDisplayMirrorsDisplay($0), "modeID": CGDisplayCopyDisplayMode($0)?.ioDisplayModeID ?? 0] }
  return ["mutationDispatched": detect || virtual ? detection["mutationDispatched"] ?? false : true,
    "detection": detection, "completeError": complete.rawValue, "displayID": display,
    "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
    "newSetupWindows": Array(newSetupWindows).sorted(), "setupUIObserved": !newSetupWindows.isEmpty,
    "onlineDisplayIDsBefore": Array(online.prefix(Int(count))),
    "onlineDisplayIDsAfter": Array(onlineAfter.prefix(Int(countAfter))),
    "onlineDisplaysUnchanged": onlineAfterError == .success && Set(online.prefix(Int(count))) == Set(onlineAfter.prefix(Int(countAfter))),
    "mirrorGroupBefore": mirrors, "mirrorGroupAfter": mirrorsAfter, "mirrorGroupUnchanged": NSArray(array: mirrors).isEqual(to: mirrorsAfter),
    "emptyTransaction": empty,
    "modeID": mode.ioDisplayModeID, "width": mode.width, "height": mode.height,
    "pixelWidth": mode.pixelWidth, "pixelHeight": mode.pixelHeight,
    "bounds": NSStringFromRect(bounds), "callbacks": events.snapshot(),
    "modeAndBoundsUnchanged": after.map { CFEqual(mode, $0) && CGDisplayBounds(display) == bounds } ?? false]
}
