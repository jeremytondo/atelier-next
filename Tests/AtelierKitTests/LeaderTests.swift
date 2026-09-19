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
    // A submenu's key comes in pieces for keycaps, as a command's does.
    #expect(top?.entries.map(\.keyPieces) == [["s"], ["w"], ["c"]])
    #expect(top?.entries.map(\.key) == ["s", "w", "c"])
    #expect(top?.entries.map(\.id) == ["s", "w", "c"])
    #expect(top?.feedback == nil)
    // Consumed, so the app never sees the W.
    #expect(mac.type("w") == false)
    let windows = await state(atelier) { $0?.title == "Windows" }
    #expect(windows?.entries.first?.label == "Fill")
    #expect(windows?.entries.first?.keyPieces == ["f"])
    #expect(windows?.entries.first?.hint == "fn⌃f")
    #expect(windows?.entries.first?.hintPieces == ["fn", "⌃", "f"])
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
    let explained = await state(atelier) { $0?.feedback == "No command for x" }
    #expect(explained?.feedback == "No command for x")
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
    let explained = await state(atelier) { $0?.feedback == "No command for ⌥w" }
    #expect(explained?.feedback == "No command for ⌥w")
  }

  @Test func spacesThatDoNotExistAreLeftOutAndTheSequenceRunsTheCommand() async throws {
    let mac = mac()
    let atelier = try await start(mac)
    _ = try await atelier.leader.open()
    mac.type("s")
    let spaces = await state(atelier) { $0?.title == "Spaces" }
    #expect(
      spaces?.entries.filter { $0.label.hasPrefix("Space ") }.map(\.label) == [
        "Space 1", "Space 2", "Space 3",
      ])
    #expect(spaces?.entries.first { $0.label == "Space 2" }?.hintPieces == ["⌥", "2"])
    #expect(spaces?.entries.first { $0.label == "New Desktop" }?.hint == "⌥`")
    #expect(spaces?.entries.first { $0.label == "New Desktop" }?.hintPieces == ["⌥", "`"])
    // A key with a modifier is a piece for each, and so is the hint beside it.
    let left = spaces?.entries.first { $0.key == "⇧h" }
    #expect(left?.keyPieces == ["⇧", "h"])
    #expect(left?.hint == "⌃⌥←")
    #expect(left?.hintPieces == ["⌃", "⌥", "←"])
    mac.type(.keyDown(Chord([.shift], "left")))
    #expect(await eventually { mac.requests == ["move 2 to 0"] })
    #expect(await eventually { await atelier.leader.state() == nil })
  }

  @Test func aNumberInTheSpacesMenuIsAPositionAmongSpacesOfEveryKind() async throws {
    // Desktop, full screen, Desktop: what the number keys and the list count too.
    let mac = FakeMac.oneDisplay(notDesktops: [2], current: 1)
    let atelier = try await start(mac)
    _ = try await atelier.leader.open()
    mac.type("s")
    let spaces = await state(atelier) { $0?.title == "Spaces" }
    #expect(
      spaces?.entries.filter { $0.label.hasPrefix("Space ") }.map(\.key) == ["1", "2", "3"])
    #expect(spaces?.entries.contains { $0.label.hasPrefix("Desktop ") } == false)
    mac.type("2")
    #expect(await eventually { mac.currentSpace == 2 })
    #expect(await eventually { await atelier.leader.state() == nil })
  }

  @Test func aDesktopNumberSomeoneBoundIsStillOfferedOnlyWhileItExists() async throws {
    let mac = FakeMac.oneDisplay(notDesktops: [2], current: 1)
    let atelier = try await start(
      mac,
      config: """
        [keymap.leader]
        "s 2" = "desktops select 2"
        "s 3" = "desktops select 3"
        "s 4" = "spaces select 0"
        "s 5" = "desktops select -1"
        """)
    _ = try await atelier.leader.open()
    mac.type("s")
    let spaces = await state(atelier) { $0?.title == "Spaces" }
    #expect(
      spaces?.entries.filter { $0.key.count == 1 && $0.key.first!.isNumber }.map(\.label) == [
        "Space 1", "Desktop 2",
      ])
  }

  /// The Mac of `mac()` with every arrangement enabled in its Window menu.
  private func arrangingMac() -> FakeMac {
    let mac = mac()
    mac.change { state in
      state.windowMenus[1] = Dictionary(
        uniqueKeysWithValues: Arrangement.allCases.map { ($0, ArrangementItem(isEnabled: true)) })
    }
    return mac
  }

  /// Opens the menu, goes down the submenus of `path`, and returns what is shown there.
  private func descend(_ atelier: Atelier, _ mac: FakeMac, _ path: String) async throws
    -> LeaderState?
  {
    _ = try await atelier.leader.open()
    let keys = path.split(separator: " ").map(String.init)
    for (depth, key) in keys.enumerated() {
      #expect(mac.type(key) == false)
      _ = await state(atelier) { $0?.path.count == depth + 1 && $0?.title != "Atelier" }
    }
    return await atelier.leader.state()
  }

  @Test(arguments: ConfigurationTests.directions.indices)
  func aVimKeyAndItsArrowRunTheSameCommand(_ index: Int) async throws {
    let direction = ConfigurationTests.directions[index]
    var requests: [[String]] = []
    for key in [direction.vim, direction.arrow] {
      let mac = arrangingMac()
      let atelier = try await start(mac)
      _ = try await descend(atelier, mac, direction.menu)
      // Consumed, and the menu closes once the command has run.
      #expect(mac.type(key) == false)
      #expect(await eventually { await atelier.leader.state() == nil })
      #expect(!mac.isListening)
      requests.append(mac.requests)
    }
    #expect(requests[0] == requests[1])
    let expected =
      switch direction.command {
      case "spaces move by -1": "move 2 to 0"
      case "spaces move by 1": "move 2 to 2"
      default: direction.command.replacing("windows ", with: "")
      }
    #expect(requests[0] == [expected])
  }

  @Test func theMenuShowsTheVimKeysAndNoArrows() async throws {
    let shown = [
      "w": ["f", "c", "h", "j", "k", "l", "t", "b", "a"],
      "w a": ["h", "j", "k", "l", "⇧h", "⇧j", "⇧k", "⇧l", "q"],
      "w t": ["h", "l"],
      "w b": ["h", "l"],
      "s": ["n", "d", "⇧h", "⇧l", "1", "2", "3"],
    ]
    for (path, keys) in shown {
      let mac = arrangingMac()
      let atelier = try await start(mac)
      let place = try await descend(atelier, mac, path)
      #expect(place?.entries.map(\.key) == keys, "in \(path)")
      await atelier.leader.close()
    }
  }

  @Test func changingOneKeyOfADirectionLeavesTheOtherAsItWas() async throws {
    let mac = arrangingMac()
    let atelier = try await start(
      mac,
      config: """
        [keymap.leader]
        "w h" = "windows arrange fill"
        "w j" = "unbind"
        "w up" = "unbind"
        "w right" = "windows arrange right"
        """)
    let windows = try await descend(atelier, mac, "w")
    // The arrow the user wrote has a row, even for the command it already ran;
    // the arrows left alone have none, whatever became of their Vim keys.
    #expect(windows?.entries.map(\.key) == ["f", "c", "h", "k", "l", "→", "t", "b", "a"])
    #expect(windows?.entries.first { $0.key == "h" }?.label == "Fill")
    #expect(windows?.entries.first { $0.key == "→" }?.label == "Right")
    mac.type("up")
    let explained = await state(atelier) { $0?.feedback == "No command for ↑" }
    #expect(explained?.feedback == "No command for ↑")
    mac.type("j")
    _ = await state(atelier) { $0?.feedback == "No command for j" }
    #expect(mac.requests.isEmpty)
    for (key, request) in [
      ("left", "arrange left"), ("down", "arrange bottom"), ("k", "arrange top"),
      ("right", "arrange right"), ("l", "arrange right"),
    ] {
      mac.change { $0.requests = [] }
      _ = try await descend(atelier, mac, "w")
      mac.type(key)
      #expect(await eventually { mac.requests == [request] }, "\(key)")
      #expect(await eventually { await atelier.leader.state() == nil })
    }
  }

  @Test func anUnavailableDirectionSaysSoByEitherKey() async throws {
    let mac = arrangingMac()
    mac.change { $0.windowMenus[1]?[.left] = ArrangementItem(isEnabled: false) }
    let atelier = try await start(mac)
    let windows = try await descend(atelier, mac, "w")
    #expect(
      windows?.entries.first { $0.key == "h" }?.unavailable
        == "Left is unavailable for the focused window.")
    for (key, listening) in [("h", 3), ("left", 5)] {
      mac.type(key)
      // The listener is off while the command is tried and on again after.
      #expect(await eventually { mac.listening.count == listening && mac.isListening }, "\(key)")
      let explained = await state(atelier) {
        $0?.feedback == "Left is unavailable for the focused window." && $0?.isShown == true
      }
      #expect(explained?.title == "Windows", "\(key)")
    }
    #expect(mac.requests.isEmpty)
  }

  @Test func aSubmenuNobodyNamedIsTitledByItsLowercaseKey() async throws {
    let mac = mac()
    let atelier = try await start(
      mac,
      config: "[keymap.leader]\n\"x n\" = \"desktops new\"\n\"x shift+y n\" = \"desktops new\"\n")
    _ = try await atelier.leader.open()
    let top = await atelier.leader.state()
    #expect(top?.path == [LeaderState.Place(label: "Atelier", isKey: false)])
    #expect(top?.entries.last?.key == "x")
    #expect(top?.entries.last?.label == "x")
    mac.type("x")
    _ = await state(atelier) { $0?.title == "x" }
    mac.type(.keyDown(Chord([.shift], "y")))
    let inner = await state(atelier) { $0?.title == "x › ⇧y" }
    #expect(inner?.path.map(\.isKey) == [true, true])
    mac.type("delete")
    mac.type("delete")
    mac.type("w")
    let windows = await state(atelier) { $0?.title == "Windows" }
    #expect(windows?.path == [LeaderState.Place(label: "Windows", isKey: false)])
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
    #expect(shown?.feedback == "No command for x")
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
