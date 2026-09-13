import Foundation
import XCTest
@testable import AtelierCore

final class JavaScriptConfigurationTests: XCTestCase {
  func testMigratesPreferencesOnceWithoutChangingSourceOrUserEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-js-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let toml = directory.appendingPathComponent("config.toml")
    let original = """
      version = 1
      spaces = false
      [bindings]
      desktop-create = "ctrl-option-n"
      [quickapps.fixture]
      app = "/Applications/Fixture.app"
      shortcut = "cmd-shift-j"
      size = [700, 500]
      """
    try Data(original.utf8).write(to: toml)
    try JavaScriptConfiguration.bootstrap(directory: directory)
    let js = directory.appendingPathComponent("init.js")
    let migrated = try String(contentsOf: js, encoding: .utf8)
    XCTAssertTrue(migrated.contains("\"spaces\" : false"))
    XCTAssertTrue(migrated.contains("/Applications/Fixture.app"))
    XCTAssertTrue(migrated.contains("ctrl-option-n"))
    XCTAssertEqual(try String(contentsOf: toml, encoding: .utf8), original)
    try Data("// my custom HS2 config".utf8).write(to: js)
    try Data("invalid TOML".utf8).write(to: toml)
    try JavaScriptConfiguration.bootstrap(directory: directory)
    XCTAssertEqual(try String(contentsOf: js, encoding: .utf8), "// my custom HS2 config")
  }
  func testInvalidLegacyConfigurationDoesNotCreateDefaultsOverIt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-js-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("invalid TOML".utf8).write(to: directory.appendingPathComponent("config.toml"))
    XCTAssertThrowsError(try JavaScriptConfiguration.bootstrap(directory: directory))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("init.js").path))
  }
}
