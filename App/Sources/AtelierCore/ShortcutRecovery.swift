import Foundation

public struct ShortcutRecoveryRecord: Codable, Equatable {
  public let id: UInt32
  public let key: UInt16
  public let flags: UInt32
  public let bootTime: Double
  public let persistedEnabled: Bool?
  public init(id: UInt32, key: UInt16, flags: UInt32, bootTime: Double, persistedEnabled: Bool?) {
    self.id = id
    self.key = key
    self.flags = flags
    self.bootTime = bootTime
    self.persistedEnabled = persistedEnabled
  }
  public func shouldRestore(key: UInt16, flags: UInt32, bootTime: Double, persistedEnabled: Bool?)
    -> Bool
  {
    abs(self.bootTime - bootTime) < 5 && self.key == key && self.flags == flags
      && self.persistedEnabled == persistedEnabled
  }
}
