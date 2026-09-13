import XCTest

@testable import AtelierCore

final class ConfigurationFilesTests: XCTestCase {
  private var directory: URL!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
  @discardableResult private func write(_ text: String, _ name: String = "config.toml") throws
    -> URL
  {
    let url = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
  }
  private func load(_ text: String) throws -> AppConfiguration {
    try ConfigurationFiles.load(write(text)).configuration
  }
  func testEmptyFileHasDefaultBindingsAndExplicitReloadAction() throws {
    let config = try load("# Defaults only\n")
    XCTAssertTrue(config.spaces && config.groups && config.overlay)
    XCTAssertNil(config.launchAtLogin)
    XCTAssertEqual(
      try config.effectiveBindings()["reload-config"], try Shortcut("ctrl-option-cmd-r"))
    XCTAssertEqual(try config.effectiveBindings().count, 28)
  }
  func testBindingsCanBeReassignedAndDisabled() throws {
    let config = try load(
      """
      [bindings]
      reload-config = "cmd-shift-r"
      desktop-1 = "none"
      group = "ctrl-g"
      """)
    let bindings = try config.effectiveBindings()
    XCTAssertNil(bindings["desktop-1"])
    XCTAssertEqual(bindings["group"], try Shortcut("ctrl-g"))
    XCTAssertEqual(bindings["reload-config"], try Shortcut("cmd-shift-r"))
  }
  func testIncludePathsAndPrecedenceAndStableQuickAppIdentity() throws {
    try write(
      """
      overlay = false
      [bindings]
      reload-config = "ctrl-r"
      [quickapps.calculator]
      app = "Calculator"
      shortcut = "cmd-shift-c"
      """, "parts/base.toml")
    try write(
      "include = [\"base.toml\"]\n[bindings]\nreload-config = \"ctrl-shift-r\"", "parts/next.toml")
    let url = try write(
      "include = [\"parts/next.toml\"]\noverlay = true\n[bindings]\nreload-config = \"cmd-shift-r\""
    )
    let first = try ConfigurationFiles.load(url)
    let second = try ConfigurationFiles.load(url)
    XCTAssertEqual(first.files.count, 3)
    XCTAssertTrue(first.configuration.overlay)
    XCTAssertEqual(
      try first.configuration.effectiveBindings()["reload-config"], try Shortcut("cmd-shift-r"))
    XCTAssertEqual(first.configuration.quickApps, second.configuration.quickApps)
    XCTAssertEqual(first.configuration.quickApps.first?.configName, "calculator")
  }
  func testNamedQuickAppsReplaceWholeEntriesAcrossIncludes() throws {
    try write(
      "[quickapps.calc]\napp = 'Calculator'\nshortcut = 'cmd-c'\nsize = [800,600]", "base.toml")
    let config = try load(
      "include = ['base.toml']\n[quickapps.calc]\napp = 'Calculator'\nshortcut = 'cmd-shift-c'\nenabled = false"
    )
    XCTAssertEqual(config.quickApps.count, 1)
    XCTAssertFalse(config.quickApps[0].enabled)
    XCTAssertNil(config.quickApps[0].size)
  }
  func testCyclesIncludingSymlinksAndMissingFilesAreErrors() throws {
    try write("include = ['config.toml']", "child.toml")
    XCTAssertThrowsError(try load("include = ['child.toml']")) {
      XCTAssertTrue($0.localizedDescription.contains("cycle"))
    }
    try FileManager.default.createSymbolicLink(
      atPath: directory.appendingPathComponent("alias.toml").path,
      withDestinationPath: directory.appendingPathComponent("config.toml").path)
    XCTAssertThrowsError(try load("include = ['alias.toml']")) {
      XCTAssertTrue($0.localizedDescription.contains("cycle"))
    }
    XCTAssertThrowsError(try load("include = ['missing.toml']")) {
      XCTAssertTrue($0.localizedDescription.contains("missing.toml"))
    }
  }
  func testUnknownKeysAndInvalidValuesNeverSilentlyFallBack() throws {
    for text in [
      "overaly = true", "spaces = 'yes'", "version = 2", "overlay-modifiers = 'cmd-a'",
      "[bindings]\nreolad = 'cmd-r'", "[bindings]\ngroup = 'g'",
      "[quickapps.calc]\napp = 'Calculator'\nshortcut = 'cmd-c'\nszie = [10,20]",
      "[quickapps.calc]\napp = 'Calculator'\nshortcut = 'cmd-c'\nsize = [0,20]",
      "[quickapps.calc]\napp = 'Calculator'\nshortcut = 'cmd-c'\nsize = [inf,20]",
      "[quickapps.calc]\napp = 'Calculator'\nshortcut = 'cmd-c'\nsize = [10]",
    ] {
      XCTAssertThrowsError(try load(text), text) {
        XCTAssertTrue($0.localizedDescription.contains("config.toml"))
      }
    }
  }
  func testSyntaxErrorReportsIncludedFileAndLine() throws {
    try write("# comment\nspaces = [", "broken.toml")
    XCTAssertThrowsError(try load("include = ['broken.toml']")) {
      XCTAssertTrue($0.localizedDescription.contains("broken.toml"))
      XCTAssertTrue($0.localizedDescription.contains("line 2"))
    }
  }
  func testConflictsAcrossQuickAppsAndBuiltInsAreRejected() throws {
    XCTAssertThrowsError(
      try load("[quickapps.calc]\napp = 'Calculator'\nshortcut = 'cmd-option-g'"))
    XCTAssertThrowsError(try load("[bindings]\nreload-config = 'cmd-option-g'"))
    let config = try load(
      "groups = false\n[quickapps.calc]\napp = 'Calculator'\nshortcut = 'cmd-option-g'")
    XCTAssertEqual(config.quickApps.count, 1)
  }
  func testStarterPreservesLegacyValuesIncludingEscapedPaths() throws {
    var original = AppConfiguration()
    original.groups = false
    original.launchAtLogin = true
    original.quickApps = [
      QuickApp(
        app: "/Applications/My \"App\".app", shortcut: try Shortcut("ctrl-option-minus"),
        size: .init(width: 901.5, height: 650), enabled: false)
    ]
    let text = ConfigurationFiles.starter(original)
    let config = try load(text)
    XCTAssertEqual(config.groups, original.groups)
    XCTAssertEqual(config.launchAtLogin, true)
    XCTAssertEqual(config.quickApps[0].app, original.quickApps[0].app)
    XCTAssertEqual(config.quickApps[0].shortcut, original.quickApps[0].shortcut)
    XCTAssertEqual(config.quickApps[0].size, original.quickApps[0].size)
    XCTAssertFalse(config.quickApps[0].enabled)
    XCTAssertFalse(text.contains("keyCode"))
    XCTAssertFalse(text.contains(original.quickApps[0].id.uuidString))
  }
  func testXDGRequiresAbsolutePathAndOtherwiseUsesDotConfig() {
    let home = URL(fileURLWithPath: "/example/home")
    XCTAssertEqual(
      ConfigurationFiles.directory(home: home, environment: [:]).path,
      "/example/home/.config/atelier")
    XCTAssertEqual(
      ConfigurationFiles.directory(home: home, environment: ["XDG_CONFIG_HOME": "/custom"]).path,
      "/custom/atelier")
    XCTAssertEqual(
      ConfigurationFiles.directory(home: home, environment: ["XDG_CONFIG_HOME": "relative"]).path,
      "/example/home/.config/atelier")
  }
}
