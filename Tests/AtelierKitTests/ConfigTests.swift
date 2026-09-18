import Foundation
import MacOS
import Testing

@testable import AtelierKit

/// The file on disk, the shortcuts registered from it, and reloading. Each
/// test has a private folder; nothing here reads the developer's file.
@Suite struct ConfigTests {
  private let folder = FileManager.default.temporaryDirectory.appending(
    path: "atelier-config-\(UUID().uuidString.prefix(8))")
  private var file: URL { folder.appending(path: "config.toml") }

  private func write(_ text: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
  }

  private func start(_ mac: FakeMac = FakeMac()) async -> Atelier {
    let atelier = Atelier(mac, configFile: file)
    await atelier.config.ready()
    return atelier
  }

  @Test func withNoFileTheDefaultShortcutsAreRegistered() async {
    let mac = FakeMac()
    let atelier = await start(mac)
    #expect(Set(mac.hotKeys).count == Defaults.global.count + 1)
    #expect(mac.hotKeys.contains(chord("cmd+option+1")))
    #expect(await atelier.config.problems().isEmpty)
    let report = await atelier.config.show()
    #expect(
      report.text.hasPrefix("File: none at \(file.path); the built-in defaults are in effect"))
  }

  @Test func aPressedShortcutRunsItsCommand() async {
    let mac = FakeMac.oneDisplay(current: 2, focusedWindow: 1, windows: [window(1, on: [2])])
    _ = await start(mac)
    mac.press(chord("option+1"))
    #expect(await eventually { mac.requests == ["switch to 1"] })
    // A chord that is not registered does nothing, whatever it is.
    mac.press(chord("cmd+option+q"))
    mac.press(chord("option+3"))
    #expect(await eventually { mac.requests == ["switch to 1", "switch to 3"] })
  }

  @Test func aPressDuringARunningCommandIsRefusedNotQueued() async {
    // Space switches take a while; a frozen switch keeps the first command running.
    let mac = FakeMac.oneDisplay(current: 1)
    mac.change { $0.ignoresSwitches = true }
    let atelier = await start(mac)
    let notices = atelier.notices.changes()
    var iterator = notices.makeAsyncIterator()
    mac.press(chord("option+2"))
    #expect(await eventually { mac.requests == ["switch to 2"] })
    mac.press(chord("option+3"))
    #expect(await iterator.next() == Notice(text: AtelierError.busy.message))
    #expect(mac.requests == ["switch to 2"])
  }

  @Test func aShortcutThatFailsIsANotice() async {
    let mac = FakeMac.oneDisplay(spaces: 1...1)
    let atelier = await start(mac)
    let notices = atelier.notices.changes()
    mac.press(chord("ctrl+option+delete"))
    var iterator = notices.makeAsyncIterator()
    #expect(await iterator.next() == Notice(text: "The only Desktop cannot be deleted."))
  }

  @Test func anAttemptThatFailsIsANotice() async {
    let atelier = await start(FakeMac.oneDisplay(spaces: 1...1))
    var iterator = atelier.notices.changes().makeAsyncIterator()
    await atelier.attempt(.desktopsDelete)
    #expect(await iterator.next() == Notice(text: "The only Desktop cannot be deleted."))
  }

  @Test func theFileAppliesAtStartupAndThenOnlyOnReload() async throws {
    try write(
      """
      [keymap.global]
      "ctrl+option+w" = "windows select 1"
      """)
    let mac = FakeMac()
    let atelier = await start(mac)
    #expect(mac.hotKeys.contains(chord("ctrl+option+w")))
    try write(
      """
      [keymap.global]
      "ctrl+option+w" = "windows select 1"
      "cmd+option+1" = "unbind"
      """)
    #expect(mac.hotKeys.contains(chord("cmd+option+1")))
    let changes = await atelier.config.changes()
    #expect(try await atelier.config.reload() == ReloadResult(outcome: .changed, problems: []))
    #expect(!mac.hotKeys.contains(chord("cmd+option+1")))
    #expect(mac.hotKeys.contains(chord("ctrl+option+w")))
    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() != nil)
    #expect(try await atelier.config.reload().outcome == .unchanged)
  }

  @Test func aRejectedReloadKeepsTheWorkingConfigurationUntilTheFileIsFixed() async throws {
    try write("[keymap.global]\n\"ctrl+option+w\" = \"spaces next\"\n")
    let mac = FakeMac.oneDisplay(current: 1)
    let atelier = await start(mac)
    try write("[keymap.global\n\"ctrl+option+w\" = \"spaces previous\"\n")
    let before = mac.hotKeys
    await #expect(throws: AtelierError.self) { try await atelier.config.reload() }
    #expect(mac.hotKeys == before)
    let problems = await atelier.config.problems()
    #expect(problems.count == 1)
    #expect(problems[0].location == "line 1")
    let shown = await atelier.config.show()
    #expect(shown.rejection == problems[0])
    #expect(shown.text.contains("Problems:\n  line 1: "))
    // The shortcuts from the last good file still run.
    mac.press(chord("ctrl+option+w"))
    #expect(await eventually { mac.requests == ["switch to 2"] })
    try write("[keymap.global]\n\"ctrl+option+w\" = \"spaces previous\"\n")
    #expect(try await atelier.config.reload().outcome == .changed)
    #expect(await atelier.config.problems().isEmpty)
  }

  @Test func theThemeAppliesAtStartupAndOnReloadAndARejectedFileKeepsIt() async throws {
    try write("theme = \"dark\"\n")
    let atelier = await start()
    #expect(await atelier.config.theme() == .dark)
    // Saving the file alone changes nothing.
    try write("theme = \"light\"\n")
    #expect(await atelier.config.theme() == .dark)
    #expect(try await atelier.config.reload().outcome == .changed)
    #expect(await atelier.config.theme() == .light)
    // A file that cannot be parsed is refused whole, and the theme stays.
    try write("theme = \"dark\n")
    await #expect(throws: AtelierError.self) { try await atelier.config.reload() }
    #expect(await atelier.config.theme() == .light)
    // A theme with a problem is left out, which means the default.
    try write("theme = \"sepia\"\n")
    let result = try await atelier.config.reload()
    #expect(result.problems.map(\.location) == ["theme"])
    #expect(await atelier.config.theme() == .system)
  }

  @Test func aRejectedFileAtStartupMeansTheDefaultsWithTheProblemOnRecord() async throws {
    try write("this is not toml")
    let mac = FakeMac()
    let atelier = await start(mac)
    #expect(Set(mac.hotKeys).count == Defaults.global.count + 1)
    let problems = await atelier.config.problems()
    #expect(problems.map(\.location) == ["line 1"])
    #expect(await atelier.config.theme() == .system)
  }

  @Test func problemsWithSettingsLeaveTheRestInEffect() async throws {
    try write(
      """
      [keymap.global]
      "ctrl+option+w" = "windows select 1"
      "ctrl+option+q" = "windows close"
      """)
    let mac = FakeMac()
    let atelier = await start(mac)
    #expect(mac.hotKeys.contains(chord("ctrl+option+w")))
    #expect(!mac.hotKeys.contains(chord("ctrl+option+q")))
    #expect(await atelier.config.problems().map(\.location) == ["keymap.global \"ctrl+option+q\""])
    let result = try await atelier.config.reload()
    #expect(result.outcome == .unchanged)
    #expect(result.problems.count == 1)
    #expect(result.text.hasPrefix("Reloaded; nothing had changed. Problems:\n  keymap.global"))
  }

  @Test func aShortcutMacOSRefusesIsAProblemAndNotABinding() async throws {
    let mac = FakeMac()
    mac.change {
      $0.refusedHotKeys[chord("option+1")] = "Another app has registered this shortcut."
    }
    let atelier = await start(mac)
    #expect(!mac.hotKeys.contains(chord("option+1")))
    #expect(
      await atelier.config.problems().map(\.text) == [
        "shortcut ⌥1: Another app has registered this shortcut."
      ])
    #expect(!(await atelier.config.show()).text.contains("  ⌥1  "))
    // Nothing runs for it even if macOS delivered a press.
    mac.press(chord("option+1"))
    mac.press(chord("option+2"))
    #expect(await eventually { mac.requests == ["switch to 2"] })
  }

  @Test func openWritesAStartingPointOnceAndOpensTheFile() async throws {
    let mac = FakeMac()
    let atelier = await start(mac)
    #expect(try await atelier.config.open() == .changed)
    #expect(try String(contentsOf: file, encoding: .utf8) == Defaults.fileTemplate)
    #expect(mac.state.withLock(\.openedFiles) == [file])
    // The template is all comments, so it changes nothing.
    #expect(try await atelier.config.reload().outcome == .unchanged)
    try write("# mine\n")
    #expect(try await atelier.config.open() == .changed)
    #expect(try String(contentsOf: file, encoding: .utf8) == "# mine\n")
    #expect(mac.state.withLock(\.openedFiles).count == 2)
  }

  @Test func checkReadsTheFileWithoutApplyingIt() async throws {
    let mac = FakeMac()
    let atelier = await start(mac)
    try write("[keymap.global]\n\"cmd+option+1\" = \"unbind\"\n\"bad\" = \"desktops new\"\n")
    let report = await atelier.config.check()
    #expect(report.problems.map(\.location) == ["keymap.global \"bad\""])
    #expect(!report.text.contains("⌥⌘1 "))
    #expect(mac.hotKeys.contains(chord("cmd+option+1")))
    #expect(await atelier.config.problems().isEmpty)
    try write("[[quick-apps]]\napp = 1\n")
    #expect(await atelier.config.check().problems.map(\.location) == ["quick-apps #1"])
    try write("nope")
    #expect(await atelier.config.check().rejection?.location == "line 1")
  }

  @Test func keysWithoutARowInTheMenuAreReportedBeforeAndAfterAReload() async throws {
    let atelier = await start()
    let marked = "    ←       windows arrange left  (not shown in the menu)"
    let listed = "\"hidden\":true,\n\"key\":\"left\""
    let defaults = await atelier.config.show()
    #expect(defaults.text.contains(marked))
    #expect(defaults.json.replacing(" ", with: "").contains(listed))
    try write("[keymap.leader]\n\"w h\" = \"unbind\"\n\"w down\" = \"windows arrange bottom\"\n")
    #expect(try await atelier.config.reload().outcome == .changed)
    let reloaded = await atelier.config.show()
    #expect(reloaded.text.contains(marked))
    #expect(reloaded.json.replacing(" ", with: "").contains(listed))
    #expect(!reloaded.text.contains("\n    h       windows arrange left\n"))
    // The arrow the file names is an ordinary key now.
    #expect(reloaded.text.contains("    ↓       windows arrange bottom\n"))
  }

  @Test func withoutAFileNothingCanBeOpened() async {
    let atelier = Atelier(FakeMac())
    await atelier.config.ready()
    await #expect(throws: AtelierError.unsupported("This Atelier has no configuration file.")) {
      try await atelier.config.open()
    }
  }
}
