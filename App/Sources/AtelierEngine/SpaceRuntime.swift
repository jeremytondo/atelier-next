import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import SpaceControlCore

private enum PrototypeError: LocalizedError {
  case accessibilityPermission
  case alreadyRunning
  case hotKey(String)
  case privateAPI(String)

  var errorDescription: String? {
    switch self {
    case .accessibilityPermission:
      "Enable Atelier in System Settings > Privacy & Security > Accessibility."
    case .alreadyRunning:
      "Another Atelier engine is running. Stop it before resuming Atelier."
    case .hotKey(let message), .privateAPI(let message):
      message
    }
  }
}

final class SingletonProcessLock {
  private let descriptor: Int32

  init() throws {
    let path = "/tmp/com.elevenideas.atelier.space-control.\(getuid()).lock"
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else {
      throw PrototypeError.privateAPI("Could not open the Space Control process lock")
    }
    guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
      close(descriptor)
      throw PrototypeError.alreadyRunning
    }
    self.descriptor = descriptor
  }

  deinit {
    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
    close(descriptor)
  }
}

private func accessibilityIsTrusted(requestIfNeeded: Bool) -> Bool {
  guard requestIfNeeded else { return AXIsProcessTrusted() }
  return AXIsProcessTrustedWithOptions(
    [
      "AXTrustedCheckOptionPrompt": true
    ] as CFDictionary)
}

func copyAXAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
    return nil
  }
  return value
}

final class SpaceRuntime {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
  private typealias GetSymbolicHotKeyValue =
    @convention(c) (
      UInt32,
      UnsafeMutablePointer<Int32>?,
      UnsafeMutablePointer<CGKeyCode>,
      UnsafeMutablePointer<UInt32>
    ) -> CGError
  private typealias IsSymbolicHotKeyEnabled = @convention(c) (UInt32) -> Bool
  private typealias SetSymbolicHotKeyEnabled = @convention(c) (UInt32, Bool) -> CGError

  private let handle: UnsafeMutableRawPointer
  private let connectionID: Int32
  private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
  private let getSymbolicHotKeyValue: GetSymbolicHotKeyValue
  private let isSymbolicHotKeyEnabled: IsSymbolicHotKeyEnabled
  private let setSymbolicHotKeyEnabled: SetSymbolicHotKeyEnabled
  private var temporarilyEnabled: Set<UInt32> = []
  private var restoreWorkItem: DispatchWorkItem?
  private var recovery: [ShortcutRecoveryRecord] = []
  private let journal: URL
  private var bootTime: Double {
    Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
  }

  init() throws {
    journal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/Atelier/temporary-shortcuts.json")
    let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
      throw PrototypeError.privateAPI("Could not open SkyLight.framework")
    }
    func symbol(_ primary: String, fallback: String? = nil) -> UnsafeMutableRawPointer? {
      dlsym(handle, primary) ?? fallback.flatMap { dlsym(handle, $0) }
    }
    guard let main = symbol("SLSMainConnectionID", fallback: "CGSMainConnectionID"),
      let copy = symbol("SLSCopyManagedDisplaySpaces", fallback: "CGSCopyManagedDisplaySpaces"),
      let get = symbol("CGSGetSymbolicHotKeyValue"),
      let isEnabled = symbol("CGSIsSymbolicHotKeyEnabled"),
      let setEnabled = symbol("CGSSetSymbolicHotKeyEnabled")
    else {
      dlclose(handle)
      throw PrototypeError.privateAPI("Required SkyLight Space/hotkey symbols are unavailable")
    }
    self.handle = handle
    let mainConnection = unsafeBitCast(main, to: MainConnection.self)
    self.connectionID = mainConnection()
    self.copyManagedDisplaySpaces = unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self)
    self.getSymbolicHotKeyValue = unsafeBitCast(get, to: GetSymbolicHotKeyValue.self)
    self.isSymbolicHotKeyEnabled = unsafeBitCast(isEnabled, to: IsSymbolicHotKeyEnabled.self)
    self.setSymbolicHotKeyEnabled = unsafeBitCast(setEnabled, to: SetSymbolicHotKeyEnabled.self)
    recoverShortcuts()
  }

  deinit {
    restoreTemporarilyEnabledHotKeys()
    dlclose(handle)
  }

  func snapshot() -> [DisplaySpaceSnapshot] {
    guard let value = copyManagedDisplaySpaces(connectionID)?.takeRetainedValue(),
      let raw = value as? [[String: Any]]
    else {
      return []
    }
    return SpaceTopology.decode(raw)
  }

  /// Posts one of macOS's own symbolic actions. Disabled actions are enabled
  /// only in the live WindowServer and restored after the event is matched;
  /// no preference is written.
  func postSymbolicHotKey(_ id: UInt32) -> Bool {
    guard let (keyCode, flags) = symbolicHotKeyValue(id) else { return false }

    if !isSymbolicHotKeyEnabled(id) {
      let record = ShortcutRecoveryRecord(
        id: id, key: keyCode, flags: flags, bootTime: bootTime,
        persistedEnabled: persistedEnabled(id))
      recovery.append(record)
      guard saveJournal() else {
        recovery.removeLast()
        return false
      }
      guard setSymbolicHotKeyEnabled(id, true) == .success else { return false }
      temporarilyEnabled.insert(id)
      scheduleRestore()
    }

    guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    else {
      return false
    }
    keyDown.flags = CGEventFlags(rawValue: UInt64(flags))
    keyUp.flags = []
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
  }

  func symbolicHotKeyValue(_ id: UInt32) -> (CGKeyCode, UInt32)? {
    var keyCode: CGKeyCode = 0
    var flags: UInt32 = 0
    guard getSymbolicHotKeyValue(id, nil, &keyCode, &flags) == .success else {
      return nil
    }
    return (keyCode, flags)
  }

  func restoreTemporarilyEnabledHotKeys() {
    restoreWorkItem?.cancel()
    restoreWorkItem = nil
    restoreRecordedShortcuts()
    temporarilyEnabled.removeAll()
  }

  private func persistedEnabled(_ id: UInt32) -> Bool? {
    let entries =
      CFPreferencesCopyAppValue(
        "AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
      as? [String: Any]
    return (entries?[String(id)] as? [String: Any])?["enabled"] as? Bool
  }

  private func saveJournal() -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: journal.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try JSONEncoder().encode(recovery).write(to: journal, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
      return true
    } catch {
      fputs("Could not record temporary shortcut state: \(error.localizedDescription)\n", stderr)
      return false
    }
  }

  private func recoverShortcuts() {
    if let data = try? Data(contentsOf: journal),
      let entries = try? JSONDecoder().decode([ShortcutRecoveryRecord].self, from: data)
    {
      recovery = entries
      restoreRecordedShortcuts()
    }
  }

  private func restoreRecordedShortcuts() {
    var failed: [ShortcutRecoveryRecord] = []
    for record in recovery {
      guard let (key, flags) = symbolicHotKeyValue(record.id),
        record.shouldRestore(
          key: key, flags: flags, bootTime: bootTime, persistedEnabled: persistedEnabled(record.id))
      else { continue }
      if isSymbolicHotKeyEnabled(record.id), setSymbolicHotKeyEnabled(record.id, false) != .success
      {
        failed.append(record)
      }
    }
    recovery = failed
    if recovery.isEmpty {
      try? FileManager.default.removeItem(at: journal)
    } else {
      _ = saveJournal()
    }
  }

  private func scheduleRestore() {
    restoreWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.restoreTemporarilyEnabledHotKeys()
    }
    restoreWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
  }
}

struct TargetDisplay {
  let displayID: CGDirectDisplayID
  let topologyIdentifier: String
}

/// The focused window's display, falling back to the pointer's display.
final class TargetDisplayResolver {
  func resolve(in topology: [DisplaySpaceSnapshot]) -> TargetDisplay? {
    if let displayID = focusedWindowDisplayID(),
      let identifier = topologyIdentifier(for: displayID, in: topology)
    {
      return TargetDisplay(displayID: displayID, topologyIdentifier: identifier)
    }
    return pointerDisplay(in: topology)
  }

  private func pointerDisplay(in topology: [DisplaySpaceSnapshot]) -> TargetDisplay? {
    guard let point = CGEvent(source: nil)?.location,
      let displayID = displayID(containing: point),
      let identifier = topologyIdentifier(for: displayID, in: topology)
    else {
      return nil
    }
    return TargetDisplay(displayID: displayID, topologyIdentifier: identifier)
  }

  private func focusedWindowDisplayID() -> CGDirectDisplayID? {
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    guard let value = copyAXAttribute(appElement, kAXFocusedWindowAttribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    let window = unsafeDowncast(value, to: AXUIElement.self)
    guard let positionValue = copyAXAttribute(window, kAXPositionAttribute),
      let sizeValue = copyAXAttribute(window, kAXSizeAttribute),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
      AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
    else {
      return nil
    }
    return displayID(containing: CGRect(origin: position, size: size))
  }

  private func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
    var display: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else {
      return nil
    }
    return display
  }

  private func displayID(containing rect: CGRect) -> CGDirectDisplayID? {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetDisplaysWithRect(rect, UInt32(displays.count), &displays, &count) == .success,
      count > 0
    else {
      return nil
    }
    return displays.prefix(Int(count)).max {
      CGDisplayBounds($0).intersection(rect).area < CGDisplayBounds($1).intersection(rect).area
    }
  }

  private func topologyIdentifier(
    for displayID: CGDirectDisplayID,
    in topology: [DisplaySpaceSnapshot]
  ) -> String? {
    if displayID == CGMainDisplayID(), topology.contains(where: { $0.identifier == "Main" }) {
      return "Main"
    }
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
      let string = CFUUIDCreateString(nil, uuid)
    else {
      return nil
    }
    let identifier = (string as String).uppercased()
    return topology.first { $0.identifier.uppercased() == identifier }?.identifier
  }
}

extension CGRect {
  fileprivate var area: CGFloat { isNull ? 0 : width * height }
}
