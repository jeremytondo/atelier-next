import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SpaceControlCore

/// macOS's own keyboard actions, posted by ID through the symbolic hotkey table.
enum SymbolicHotKey {
  static let missionControl: UInt32 = 32
  static let previousSpace: UInt32 = 79
  static let nextSpace: UInt32 = 81

  /// "Switch to Desktop N", registered by Dock for the first sixteen Desktops.
  static func desktop(_ number: Int) -> UInt32 {
    UInt32(117 + number)
  }
}

/// Space topology and macOS's own Space shortcuts. Disabled shortcuts are
/// enabled only in the live WindowServer session for the moment an event is
/// posted, journaled so a later launch can restore the user's setting if this
/// process dies mid-operation, and never written to preferences.
final class SpaceRuntime {
  private let api: PrivateAPI
  private var temporarilyEnabled: Set<UInt32> = []
  private var restoreWorkItem: DispatchWorkItem?
  private var recovery: [ShortcutRecoveryRecord] = []
  private let journal: URL
  private var bootTime: Double {
    Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
  }

  init(api: PrivateAPI) {
    self.api = api
    journal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/Atelier/temporary-shortcuts.json")
    recoverShortcuts()
  }

  deinit {
    restoreTemporarilyEnabledHotKeys()
  }

  func snapshot() -> [DisplaySpaceSnapshot] {
    SpaceTopology.decode(api.managedDisplaySpaces())
  }

  func currentSpaceID(on displayIdentifier: String) -> UInt64? {
    snapshot().first { $0.identifier == displayIdentifier }?.currentSpaceID
  }

  func postSymbolicHotKey(_ id: UInt32) -> Bool {
    guard let (keyCode, flags) = api.symbolicHotKeyValue(id) else { return false }

    if !api.isSymbolicHotKeyEnabled(id) {
      let record = ShortcutRecoveryRecord(
        id: id, key: keyCode, flags: flags, bootTime: bootTime,
        persistedEnabled: persistedEnabled(id))
      recovery.append(record)
      guard saveJournal() else {
        recovery.removeLast()
        return false
      }
      guard api.setSymbolicHotKeyEnabled(id, true) else { return false }
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
      guard let (key, flags) = api.symbolicHotKeyValue(record.id),
        record.shouldRestore(
          key: key, flags: flags, bootTime: bootTime, persistedEnabled: persistedEnabled(record.id))
      else { continue }
      if api.isSymbolicHotKeyEnabled(record.id), !api.setSymbolicHotKeyEnabled(record.id, false) {
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
