import Foundation
import MacOS
import Testing

@testable import AtelierKit

/// The leader menu, driven through a fake key listener: what each key does,
/// what the listener consumes, and when it exists at all.
@Suite struct LeaderTests {
  private let folder = FileManager.default.temporaryDirectory.appending(
    path: "atelier-leader-\(UUID().uuidString.prefix(8))")

  /// A Mac showing Desktop 2 of three, window 1 focused, with a Window menu
  /// that has Fill but not Center enabled.
  private func mac() -> FakeMac {
    let mac = FakeMac.oneDisplay(
      current: 2, focusedWindow: 1, windows: [window(1, on: [2]), window(2, on: [2])])
    mac.change {
      $0.windowMenus[1] = [
        .fill: ArrangementItem(isEnabled: true, shortcut: Chord([.function, .control], "f")),
        .center: ArrangementItem(isEnabled: false),
      ]
    }
    return mac
  }

  private func start(_ mac: FakeMac, config: String? = nil) async throws -> Atelier {
    var file: URL?
    if let config {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      file = folder.appending(path: "config.toml")
      try config.write(to: file!, atomically: true, encoding: .utf8)
    }
    let atelier = Atelier(mac, configFile: file)
    await atelier.config.ready()
    return atelier
  }

  private func state(
    _ atelier: Atelier, where condition: @escaping @Sendable (LeaderState?) -> Bool
  )
    async -> LeaderState?
  {
    _ = await eventually { condition(await atelier.leader.state()) }
    return await atelier.leader.state()
  }

  @Test func opensAtTheTopDescendsAndRunsACommand() async throws {
    let mac = mac()
    let atelier = try await start(mac)
    #expect(!mac.isListening)
    #expect(try await atelier.leader.open() == .changed)
    #expect(mac.isListening)
    let top = await atelier.leader.state()
    #expect(top?.title == "Atelier")
    #expect(top?.isShown == true)
    #expect(top?.display == "only")
    #expect(top?.entries.map(\.label) == ["Spaces", "Windows", "Configuration"])
    #expect(top?.entries.map(\.isSubmenu) == [true, true, true])
    #expect(top?.feedback == nil)
    // Consumed, so the app never sees the W.
    #expect(mac.type("w") == false)
    let windows = await state(atelier) { $0?.title == "Windows" }
    #expect(windows?.entries.first?.label == "Fill")
    #expect(windows?.entries.first?.hint == "fn⌃F")
    #expect(windows?.entries.first?.unavailable == nil)
    #expect(windows?.entries[1].unavailable == "Center is unavailable for the focused window.")
    #expect(windows?.entries.map(\.label).contains("Arrange") == true)
    #expect(mac.type("f") == false)
    #expect(await eventually { mac.requests == ["arrange fill"] })
    #expect(await eventually { await atelier.leader.state() == nil })
    #expect(!mac.isListening)
    #expect(mac.listening == ["start", "stop"])
  }

  @Test func unknownKeysAndUnavailableCommandsKeepTheMenuOpenWithAWord() async throws {
    let mac = mac()
    let atelier = try await start(mac)
    _ = try await atelier.leader.open()
    #expect(mac.type("x") == false)
    let explained = await state(atelier) { $0?.feedback == "No command for X" }
    #expect(explained?.feedback == "No command for X")
    #expect(explained?.title == "Atelier")
    #expect(mac.type(.keyDown(Chord([], ""))) == false)
    _ = await state(atelier) { $0?.feedback == "Unknown key" }
    mac.type("w")
    _ = await state(atelier) { $0?.title == "Windows" }
    mac.type("c")
    let unavailable = await state(atelier) {
      $0?.feedback == "Center is unavailable for the focused window."
    }
    #expect(unavailable?.feedback == "Center is unavailable for the focused window.")
    #expect(unavailable?.title == "Windows")
    #expect(mac.requests.isEmpty)
    // The listener was off while the command ran and is on again.
    #expect(mac.listening == ["start", "stop", "start"])
    #expect(mac.isListening)
    mac.type("delete")
    _ = await state(atelier) { $0?.title == "Atelier" }
    #expect(mac.type("escape") == false)
    #expect(await eventually { await atelier.leader.state() == nil })
    #expect(!mac.isListening)
  }

  @Test func clicksCmdTabAndAppSwitchesCloseTheMenuAndPassThrough() async throws {
    let mac = mac()
    let atelier = try await start(mac)
    for event in [KeyEvent.mouseDown, .keyDown(Chord([.command], "tab")), .appSwitched] {
      _ = try await atelier.leader.open()
      #expect(mac.type(event) == true)
      #expect(await eventually { await atelier.leader.state() == nil })
      #expect(!mac.isListening)
    }
  }

  @Test func theLeadersOwnModifiersAreIgnoredUntilReleased() async throws {
    let mac = mac()
    let atelier = try await start(mac)
    _ = try await atelier.leader.open()
    mac.type(.keyDown(Chord([.option], "w")))
    _ = await state(atelier) { $0?.title == "Windows" }
    // The leader key again returns to the top.
    mac.type(.keyDown(Chord([.option], "space")))
    _ = await state(atelier) { $0?.title == "Atelier" }
    mac.type(.flagsChanged([]))
    mac.type(.keyDown(Chord([.option], "w")))
    let explained = await state(atelier) { $0?.feedback == "No command for ⌥W" }
    #expect(explained?.feedback == "No command for ⌥W")
  }

  @Test func desktopsThatDoNotExistAreLeftOutAndTheSequenceRunsTheCommand() async throws {
    let mac = mac()
    let atelier = try await start(mac)
    _ = try await atelier.leader.open()
    mac.type("s")
    let spaces = await state(atelier) { $0?.title == "Spaces" }
    #expect(
      spaces?.entries.filter { $0.label.hasPrefix("Desktop ") }.map(\.label) == [
        "Desktop 1", "Desktop 2", "Desktop 3",
      ])
    #expect(spaces?.entries.first { $0.label == "New Desktop" }?.hint == "⌥`")
    mac.type(.keyDown(Chord([.shift], "left")))
    #expect(await eventually { mac.requests == ["move 2 to 0"] })
    #expect(await eventually { await atelier.leader.state() == nil })
  }

  @Test func theLeaderKeyOpensItAndTheConfigurationShapesIt() async throws {
    let mac = mac()
    let atelier = try await start(
      mac,
      config: """
        [leader]
        key = "ctrl+space"
        delay = 0.3
        timeout = 0.8

        [keymap.leader]
        "x" = { menu = "Extras" }
        "x n" = "desktops new"
        "c" = "unbind"
        """)
    #expect(mac.hotKeys.contains(chord("ctrl+space")))
    mac.press(chord("ctrl+space"))
    let hidden = await state(atelier) { $0 != nil }
    #expect(hidden?.isShown == false)
    #expect(hidden?.entries.map(\.label) == ["Spaces", "Windows", "Extras"])
    let shown = await state(atelier) { $0?.isShown == true }
    #expect(shown != nil)
    // Nothing pressed for the timeout: the menu closes on its own.
    #expect(await eventually { await atelier.leader.state() == nil })
    #expect(!mac.isListening)
  }

  @Test func reloadingFromTheMenuOrElsewhereClosesIt() async throws {
    let mac = mac()
    let atelier = try await start(mac, config: "[keymap.global]\n\"bad\" = \"desktops new\"\n")
    let notices = atelier.notices.changes()
    var iterator = notices.makeAsyncIterator()
    _ = try await atelier.leader.open()
    mac.type("c")
    _ = await state(atelier) { $0?.title == "Configuration" }
    mac.type("r")
    #expect(await eventually { await atelier.leader.state() == nil })
    #expect(await iterator.next()?.text == "Reloaded with 1 problem; see atelier config show.")
    _ = try await atelier.leader.open()
    _ = try await atelier.config.reload()
    #expect(await eventually { await atelier.leader.state() == nil })
    #expect(!mac.isListening)
  }

  @Test func aWordRevealsTheMenuBeforeItsDelay() async throws {
    let mac = mac()
    let atelier = try await start(mac, config: "[leader]\ndelay = 5\n")
    _ = try await atelier.leader.open()
    #expect(await atelier.leader.state()?.isShown == false)
    mac.type("x")
    let shown = await state(atelier) { $0?.isShown == true }
    #expect(shown?.feedback == "No command for X")
    await atelier.leader.close()
    #expect(await atelier.leader.state() == nil)
  }

  @Test func withoutAListenerTheMenuDoesNotOpen() async throws {
    let mac = mac()
    mac.change { $0.refusesListening = true }
    let atelier = try await start(mac)
    await #expect(throws: AtelierError.self) { try await atelier.leader.open() }
    #expect(await atelier.leader.state() == nil)
    mac.change { $0.hasAccessibility = false }
    await #expect(throws: AtelierError.accessibilityRequired) { try await atelier.leader.open() }
  }
}
