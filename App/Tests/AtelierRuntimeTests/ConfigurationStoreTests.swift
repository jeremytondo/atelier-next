import AtelierCore
import XCTest

@testable import Atelier

final class ConfigurationStoreTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  @MainActor private func store() -> ConfigurationStore {
    ConfigurationStore(
      directory: root.appendingPathComponent("config"),
      stateDirectory: root.appendingPathComponent("state"),
      legacyQuickApps: root.appendingPathComponent("quickapps.js"), loginEnabled: false)
  }
  func testLegacyJSONIsMigratedOnceAndPreservedByteForByte() async throws {
    try await MainActor.run {
      var legacy = AppConfiguration()
      legacy.quickApps = [QuickApp(app: "Calculator", shortcut: try Shortcut("cmd-shift-c"))]
      let url = root.appendingPathComponent("state/settings.json")
      let data = try JSONEncoder().encode(legacy)
      try data.write(to: url)
      let first = store()
      XCTAssertFalse(first.loadFailed)
      XCTAssertEqual(first.configuration.quickApps.first?.shortcut, try Shortcut("cmd-shift-c"))
      XCTAssertEqual(try Data(contentsOf: url), data)
      // A broken legacy file cannot affect the new source of truth.
      try Data("broken legacy JSON".utf8).write(to: url)
      let second = store()
      XCTAssertFalse(second.loadFailed)
      XCTAssertEqual(second.configuration.quickApps, first.configuration.quickApps)
    }
  }
  func testSavingDoesNothingUntilExplicitReadAndCommitAndNeverRewritesComments() async throws {
    try await MainActor.run {
      let settings = store()
      let text = "# Keep my formatting and comments.\noverlay = false\n"
      try Data(text.utf8).write(to: settings.url, options: .atomic)
      XCTAssertTrue(settings.configuration.overlay)
      let candidate = try settings.read()
      XCTAssertTrue(settings.configuration.overlay)
      settings.accept(candidate)
      XCTAssertFalse(settings.configuration.overlay)
      XCTAssertEqual(try String(contentsOf: settings.url, encoding: .utf8), text)
      try Data("overlay = invalid".utf8).write(to: settings.url)
      XCTAssertThrowsError(try settings.read())
      XCTAssertFalse(settings.configuration.overlay)
      XCTAssertFalse(settings.loadFailed)
    }
  }
  func testExistingBrokenConfigDoesNotFallBackToLegacyOrOverwriteIt() async throws {
    try await MainActor.run {
      let settings = store()
      let data = Data("# Fix me\noverlay = nope".utf8)
      try data.write(to: settings.url)
      let second = store()
      XCTAssertTrue(second.loadFailed)
      XCTAssertEqual(try Data(contentsOf: second.url), data)
    }
  }
  func testPrototypeImportIsDataOnlyAndHammerspoonFileIsUnchanged() async throws {
    try await MainActor.run {
      let source = "module.exports = [{app: 'Calculator', shortcut: 'cmd-shift-c'}];"
      let url = root.appendingPathComponent("quickapps.js")
      try Data(source.utf8).write(to: url)
      let settings = store()
      XCTAssertEqual(settings.configuration.quickApps.first?.app, "Calculator")
      XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }
  }
  func testFailedImportDoesNotCreateEmptyConfigOverUserIntent() async throws {
    try await MainActor.run {
      try Data("module.exports = loadMyApps();".utf8).write(
        to: root.appendingPathComponent("quickapps.js"))
      let settings = store()
      XCTAssertTrue(settings.loadFailed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: settings.url.path))
    }
  }
}
