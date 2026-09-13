import XCTest
@testable import AtelierCore

final class BehaviorTests: XCTestCase {
  func testImportPreservesConfiguredShortcutAndSizeWithoutExecutingCode() throws {
    let source = """
      // Prototype config
      module.exports = [
        {app: 'Calculator', shortcut: 'cmd-shift-c'},
        // optional app
        {app: "com.example.app", shortcut: 'ctrl-option-left-bracket', size: {width: 900, height: 650}},
      ];
      """
    let imported = try QuickAppImporter.parse(source)
    XCTAssertEqual(imported.count, 2)
    XCTAssertEqual(imported[0].shortcut, try Shortcut("command-shift-c"))
    XCTAssertEqual(imported[1].size, QuickApp.Size(width: 900, height: 650))
    XCTAssertThrowsError(try QuickAppImporter.parse("module.exports = require('secrets');"))
    XCTAssertThrowsError(
      try QuickAppImporter.parse(
        "module.exports = [{ app: (() => 'Calculator')(), shortcut: 'cmd-c' }];"))
    XCTAssertThrowsError(try QuickAppImporter.parse("run(); module.exports = [];"))
  }
  func testConfigurationRejectsInvalidValuesAndRoundTrips() throws {
    var config = AppConfiguration()
    config.quickApps = [QuickApp(app: "Calculator", shortcut: try Shortcut("cmd-shift-c"))]
    let decoded = try JSONDecoder().decode(
      AppConfiguration.self, from: JSONEncoder().encode(config))
    XCTAssertEqual(decoded, config)
    config.quickApps[0].size = .init(width: -1, height: 300)
    XCTAssertThrowsError(try config.validate())
    XCTAssertThrowsError(try Shortcut("ctrl-ctrl-c"))
    XCTAssertThrowsError(try Shortcut("c"))
    config.schemaVersion = 99
    XCTAssertThrowsError(try config.validate())
  }
  func testShortcutRecoveryPreservesUserChangesAndIgnoresEarlierBoots() {
    let record = ShortcutRecoveryRecord(
      id: 118, key: 18, flags: 0, bootTime: 100, persistedEnabled: false)
    XCTAssertTrue(record.shouldRestore(key: 18, flags: 0, bootTime: 100.1, persistedEnabled: false))
    XCTAssertFalse(record.shouldRestore(key: 18, flags: 0, bootTime: 100, persistedEnabled: true))
    XCTAssertFalse(record.shouldRestore(key: 19, flags: 0, bootTime: 100, persistedEnabled: false))
    XCTAssertFalse(record.shouldRestore(key: 18, flags: 0, bootTime: 200, persistedEnabled: false))
  }
}
