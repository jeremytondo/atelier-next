import Foundation

/// A symbolic hotkey the engine enabled temporarily, journaled so a later
/// launch can restore the user's setting if this process dies mid-operation.
struct ShortcutRecoveryRecord: Codable, Equatable {
  let id: UInt32
  let key: UInt16
  let flags: UInt32
  let bootTime: Double
  let persistedEnabled: Bool?
  func shouldRestore(key: UInt16, flags: UInt32, bootTime: Double, persistedEnabled: Bool?)
    -> Bool
  {
    abs(self.bootTime - bootTime) < 5 && self.key == key && self.flags == flags
      && self.persistedEnabled == persistedEnabled
  }
}
