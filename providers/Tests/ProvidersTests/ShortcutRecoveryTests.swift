import Testing

@testable import Providers

@Test func shortcutRecoveryPreservesUserChangesAndIgnoresEarlierBoots() {
  let record = ShortcutRecoveryRecord(
    id: 118, key: 18, flags: 0, bootTime: 100, persistedEnabled: false)
  #expect(record.shouldRestore(key: 18, flags: 0, bootTime: 100.1, persistedEnabled: false))
  #expect(!record.shouldRestore(key: 18, flags: 0, bootTime: 100, persistedEnabled: true))
  #expect(!record.shouldRestore(key: 19, flags: 0, bootTime: 100, persistedEnabled: false))
  #expect(!record.shouldRestore(key: 18, flags: 0, bootTime: 200, persistedEnabled: false))
}
