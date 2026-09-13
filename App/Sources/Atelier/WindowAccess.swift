import AppKit
import ApplicationServices
import AtelierCore

@MainActor
final class WindowAccess {
  private typealias GetID =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
  private typealias Connection = @convention(c) () -> Int32
  private typealias Membership = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
  private typealias Topology = @convention(c) (Int32) -> Unmanaged<CFArray>?
  private let axHandle: UnsafeMutableRawPointer
  private let skyHandle: UnsafeMutableRawPointer
  private let getID: GetID
  private let connection: Int32
  private let membership: Membership
  private let topology: Topology
  init() throws {
    guard
      let ax = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
      let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
      let wid = dlsym(ax, "_AXUIElementGetWindow"), let c = dlsym(sky, "SLSMainConnectionID"),
      let m = dlsym(sky, "SLSCopySpacesForWindows"),
      let t = dlsym(sky, "SLSCopyManagedDisplaySpaces")
    else {
      throw AppError(
        "This macOS version does not expose the window and Desktop capabilities Atelier needs.")
    }
    axHandle = ax
    skyHandle = sky
    getID = unsafeBitCast(wid, to: GetID.self)
    connection = unsafeBitCast(c, to: Connection.self)()
    membership = unsafeBitCast(m, to: Membership.self)
    topology = unsafeBitCast(t, to: Topology.self)
  }
  deinit {
    dlclose(axHandle)
    dlclose(skyHandle)
  }
  func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
      ? value : nil
  }
  func application(_ pid: Int32) -> AXUIElement {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.2)
    return element
  }
  func id(_ element: AXUIElement) -> UInt32 {
    var id: UInt32 = 0
    return getID(element, &id) == .success ? id : 0
  }
  func focusedKey() -> WindowKey? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let focused = attribute(application(pid), kAXFocusedWindowAttribute),
      CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    return WindowKey(pid: pid, id: id(unsafeDowncast(focused, to: AXUIElement.self)))
  }
  func element(_ key: WindowKey) -> AXUIElement? {
    (attribute(application(key.pid), kAXWindowsAttribute) as? [AXUIElement])?.first {
      id($0) == key.id
    }
  }
  func frame(_ element: AXUIElement) -> WindowFrame? {
    guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
      let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &point),
      AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size)
    else { return nil }
    return WindowFrame(x: point.x, y: point.y, w: size.width, h: size.height)
  }
  func belongs(_ key: WindowKey, to space: String) -> Bool {
    let ids =
      membership(connection, 7, [NSNumber(value: key.id)] as CFArray)?.takeRetainedValue()
      as? [NSNumber] ?? []
    return ids.map(\.stringValue) == [space]
  }
  func isCurrent(_ key: GroupKey) -> Bool {
    guard let displays = topology(connection)?.takeRetainedValue() as? [[String: Any]],
      let display = displays.first(where: { $0["Display Identifier"] as? String == key.display }),
      let current = display["Current Space"] as? [String: Any],
      let id = (current["ManagedSpaceID"] ?? current["id64"]) as? NSNumber
    else { return false }
    return id.stringValue == key.space
  }
  func focus(_ window: WindowRecord, group: GroupKey, valid: () -> Bool) async throws -> AXUIElement
  {
    guard valid(), isCurrent(group), belongs(window.key, to: group.space),
      let element = element(window.key)
    else {
      throw AppError("The selected window or Desktop changed. Try again.")
    }
    if focusedKey() == window.key { return element }
    let app = application(window.pid)
    AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    let end = ProcessInfo.processInfo.systemUptime + 0.5
    repeat {
      guard valid(), isCurrent(group) else { throw CancellationError() }
      if focusedKey() == window.key { return element }
      try await Task.sleep(for: .milliseconds(5))
    } while ProcessInfo.processInfo.systemUptime < end
    throw AppError("Could not focus the exact window in \(window.app).")
  }
}

@MainActor
final class WindowObservers {
  private final class Entry {
    let observer: AXObserver
    let app: AXUIElement
    var windows: [WindowKey: AXUIElement] = [:]
    init(observer: AXObserver, app: AXUIElement) {
      self.observer = observer
      self.app = app
    }
  }
  private var entries: [Int32: Entry] = [:]
  var changed: ((Int32, String) -> Void)?
  private let appEvents = [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification]
  private let windowEvents = [
    kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
    kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
  ]
  func sync(_ windows: [WindowRecord], access: WindowAccess) {
    let pids = Set(windows.map(\.pid))
    for pid in Array(entries.keys) where !pids.contains(pid) { remove(pid) }
    for pid in pids {
      if entries[pid] == nil {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, event, context in
          guard let context else { return }
          var pid: pid_t = 0
          AXUIElementGetPid(element, &pid)
          MainActor.assumeIsolated {
            Unmanaged<WindowObservers>.fromOpaque(context).takeUnretainedValue().changed?(
              pid, event as String)
          }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
        let entry = Entry(observer: observer, app: access.application(pid))
        for event in appEvents {
          AXObserverAddNotification(
            observer, entry.app, event as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        entries[pid] = entry
      }
      guard let entry = entries[pid] else { continue }
      let keys = Set(windows.filter { $0.pid == pid }.map(\.key))
      for key in Array(entry.windows.keys) where !keys.contains(key) {
        if let element = entry.windows.removeValue(forKey: key) {
          for event in windowEvents {
            AXObserverRemoveNotification(entry.observer, element, event as CFString)
          }
        }
      }
      for key in keys where entry.windows[key] == nil {
        guard let element = access.element(key) else { continue }
        for event in windowEvents {
          AXObserverAddNotification(
            entry.observer, element, event as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        entry.windows[key] = element
      }
    }
  }
  private func remove(_ pid: Int32) {
    guard let entry = entries.removeValue(forKey: pid) else { return }
    CFRunLoopRemoveSource(
      CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)
    for event in appEvents {
      AXObserverRemoveNotification(entry.observer, entry.app, event as CFString)
    }
    for element in entry.windows.values {
      for event in windowEvents {
        AXObserverRemoveNotification(entry.observer, element, event as CFString)
      }
    }
  }
  func stop() { for pid in Array(entries.keys) { remove(pid) } }
}
