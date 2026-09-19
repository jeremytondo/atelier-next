import MacOS
import Testing

@testable import AtelierKit

/// Reading the file and laying it over the defaults, with no Mac involved.
@Suite struct ConfigurationTests {
  private func resolve(_ text: String, spaceChords: Set<Chord> = []) -> Configuration {
    switch Overrides.parse(text) {
    case .success(let overrides): return Keymap.resolve(overrides, spaceShortcuts: spaceChords)
    case .failure(let problem):
      Issue.record("The file was rejected: \(problem.text)")
      return Keymap.resolve(Overrides(), spaceShortcuts: [])
    }
  }

  private func keys(of menu: Menu) -> [String] {
    menu.entries.map { KeyGrammar.text($0.chord) }
  }

  private func submenu(_ menu: Menu, _ key: String) -> Menu? {
    for case .submenu(let chord, let submenu) in menu.entries where chord == self.chord(key) {
      return submenu
    }
    return nil
  }

  private func command(_ menu: Menu, _ key: String) -> Command? {
    for case .command(let chord, let command, _) in menu.entries where chord == self.chord(key) {
      return command
    }
    return nil
  }

  private func chord(_ text: String) -> Chord { AtelierKitTests.chord(text) }

  /// The submenu at a sequence of keys, such as `w a`.
  private func menu(_ configuration: Configuration, at path: String) -> Menu? {
    path.split(separator: " ").reduce(configuration.menu) { menu, key in
      menu.flatMap { submenu($0, String(key)) }
    }
  }

  /// Nil when nothing is bound at the key.
  private func isHidden(_ menu: Menu, _ key: String) -> Bool? {
    for case .command(let chord, _, let isHidden) in menu.entries where chord == self.chord(key) {
      return isHidden
    }
    return nil
  }

  /// Every direction the leader offers: where, the Vim key, the arrow, the command.
  static let directions: [(menu: String, vim: String, arrow: String, command: String)] = [
    ("w", "h", "left", "windows arrange left"),
    ("w", "j", "down", "windows arrange bottom"),
    ("w", "k", "up", "windows arrange top"),
    ("w", "l", "right", "windows arrange right"),
    ("w a", "h", "left", "windows arrange left-right"),
    ("w a", "j", "down", "windows arrange bottom-top"),
    ("w a", "k", "up", "windows arrange top-bottom"),
    ("w a", "l", "right", "windows arrange right-left"),
    ("w a", "shift+h", "shift+left", "windows arrange left-quarters"),
    ("w a", "shift+j", "shift+down", "windows arrange bottom-quarters"),
    ("w a", "shift+k", "shift+up", "windows arrange top-quarters"),
    ("w a", "shift+l", "shift+right", "windows arrange right-quarters"),
    ("w t", "h", "left", "windows arrange top-left"),
    ("w t", "l", "right", "windows arrange top-right"),
    ("w b", "h", "left", "windows arrange bottom-left"),
    ("w b", "l", "right", "windows arrange bottom-right"),
    ("s", "shift+h", "shift+left", "spaces move by -1"),
    ("s", "shift+l", "shift+right", "spaces move by 1"),
  ]

  @Test func theDefaultsAreTheEverydayKeysAndNoQuickApps() {
    let configuration = resolve("")
    #expect(configuration.problems.isEmpty)
    #expect(configuration.global.count == Defaults.global.count)
    // A number is a position among Spaces of every kind, 0 standing for the tenth.
    #expect(configuration.global[chord("option+1")] == .spacesSelect(1))
    #expect(configuration.global[chord("option+0")] == .spacesSelect(10))
    #expect(configuration.global[chord("option+shift+3")] == .spacesMoveTo(3))
    #expect(configuration.global[chord("option+shift+0")] == .spacesMoveTo(10))
    #expect(configuration.global[chord("option+[")] == nil)
    #expect(configuration.global[chord("option+shift+]")] == nil)
    #expect(configuration.global[chord("cmd+option+3")] == .windowsSelect(3))
    #expect(configuration.global[chord("cmd+option+shift+3")] == .windowsMove(.toSlot(3)))
    #expect(configuration.global[chord("cmd+option+]")] == .windowsCycle(.next))
    #expect(configuration.global[chord("ctrl+option+left")] == .spacesMoveBy(-1))
    #expect(configuration.global[chord("ctrl+option+delete")] == .desktopsDelete)
    #expect(configuration.global[chord("ctrl+option+cmd+r")] == .configReload)
    #expect(configuration.leader == Defaults.leader)
    #expect(configuration.windowListModifiers == [.command, .option])
    #expect(
      configuration.spaceList
        == SpaceListSettings(modifiers: [.option], delay: .milliseconds(200), isEnabled: true))
    #expect(configuration.quickApps.isEmpty)
    // Quick Apps has nothing under it, so it is not offered.
    #expect(keys(of: configuration.menu) == ["s", "w", "c"])
    let windows = submenu(configuration.menu, "w")
    #expect(windows?.label == "Windows")
    #expect(
      windows.map(keys) == [
        "f", "c", "h", "left", "j", "down", "k", "up", "l", "right", "t", "b", "a",
      ])
    #expect(command(windows!, "f") == .windowsArrange(.fill))
    #expect(command(submenu(windows!, "a")!, "shift+left") == .windowsArrange(.leftQuarters))
    let spaces = submenu(configuration.menu, "s")!
    #expect(command(spaces, "shift+right") == .spacesMoveBy(1))
    #expect(command(spaces, "2") == .spacesSelect(2))
    #expect(command(spaces, "0") == .spacesSelect(10))
  }

  @Test(arguments: ConfigurationTests.directions.indices)
  func eachDirectionHasAVimKeyShownAndAnArrowHidden(_ index: Int) throws {
    let direction = Self.directions[index]
    let place = try #require(menu(resolve(""), at: direction.menu))
    let expected = try #require(Command(words: direction.command))
    #expect(command(place, direction.vim) == expected)
    #expect(command(place, direction.arrow) == expected)
    #expect(isHidden(place, direction.vim) == false)
    #expect(isHidden(place, direction.arrow) == true)
  }

  @Test func cornersGoLeftAndRightByHAndLAndNothingElse() throws {
    let configuration = resolve("")
    for corner in ["w t", "w b"] {
      let place = try #require(menu(configuration, at: corner))
      #expect(keys(of: place) == ["h", "left", "l", "right"])
    }
    // Only the directions are hidden; every other shipped key has its row.
    func hidden(_ menu: Menu) -> Int {
      menu.entries.reduce(0) { count, entry in
        switch entry {
        case .command(_, _, let isHidden): count + (isHidden ? 1 : 0)
        case .submenu(_, let submenu): count + hidden(submenu)
        }
      }
    }
    #expect(hidden(configuration.menu) == Self.directions.count)
  }

  @Test func aVimKeyAndItsArrowAreChangedOneAtATime() throws {
    let configuration = resolve(
      """
      [keymap.leader]
      "w h" = "desktops new"
      "w j" = "unbind"
      "w up" = "unbind"
      "w right" = "windows arrange right"
      "w a shift+left" = "windows arrange fill"
      "w t l" = "windows arrange top-left"
      "w t r" = "windows arrange top-right"
      """)
    #expect(configuration.problems.isEmpty)
    let windows = try #require(menu(configuration, at: "w"))
    // Changing or removing the Vim key leaves its arrow working and unseen.
    #expect(command(windows, "h") == .desktopsNew)
    #expect(command(windows, "left") == .windowsArrange(.left))
    #expect(isHidden(windows, "left") == true)
    #expect(command(windows, "j") == nil)
    #expect(command(windows, "down") == .windowsArrange(.bottom))
    #expect(isHidden(windows, "down") == true)
    // Removing the arrow leaves its Vim key.
    #expect(command(windows, "up") == nil)
    #expect(command(windows, "k") == .windowsArrange(.top))
    #expect(isHidden(windows, "k") == false)
    // An arrow the user wrote is shown, even for the command it already ran.
    #expect(command(windows, "right") == .windowsArrange(.right))
    #expect(isHidden(windows, "right") == false)
    #expect(isHidden(windows, "l") == false)
    let arrange = try #require(menu(configuration, at: "w a"))
    #expect(command(arrange, "shift+left") == .windowsArrange(.fill))
    #expect(isHidden(arrange, "shift+left") == false)
    #expect(command(arrange, "shift+h") == .windowsArrange(.leftQuarters))
    // The corner keys of an earlier file still win, and keep their places.
    let top = try #require(menu(configuration, at: "w t"))
    #expect(keys(of: top) == ["h", "left", "l", "right", "r"])
    #expect(command(top, "l") == .windowsArrange(.topLeft))
    #expect(command(top, "r") == .windowsArrange(.topRight))
    #expect(command(top, "right") == .windowsArrange(.topRight))
  }

  @Test func aSubmenuNobodyNamedIsLabelledByItsLowercaseKey() throws {
    let configuration = resolve(
      """
      [keymap.leader]
      "X n" = "desktops new"
      "shift+y n" = "desktops new"
      "z" = { menu = "Zed" }
      "z n" = "desktops new"
      """)
    #expect(configuration.problems.isEmpty)
    #expect(submenu(configuration.menu, "x")?.label == "x")
    #expect(submenu(configuration.menu, "x")?.isLabelKey == true)
    #expect(submenu(configuration.menu, "shift+y")?.label == "⇧y")
    #expect(submenu(configuration.menu, "z")?.label == "Zed")
    #expect(submenu(configuration.menu, "z")?.isLabelKey == false)
    #expect(submenu(configuration.menu, "w")?.isLabelKey == false)
    #expect(configuration.menu.isLabelKey == false)
  }

  @Test func anEntryOverridesItsKeyAndUnbindRemovesIt() {
    let configuration = resolve(
      """
      [keymap.global]
      "ctrl+option+w" = "windows select 1"
      "cmd+option+1" = "unbind"
      "option+1" = "desktops select 2"
      """)
    #expect(configuration.problems.isEmpty)
    #expect(configuration.global[chord("ctrl+option+w")] == .windowsSelect(1))
    #expect(configuration.global[chord("cmd+option+1")] == nil)
    #expect(configuration.global[chord("option+1")] == .desktopsSelect(2))
    // Another key for a command leaves its default key in place.
    #expect(configuration.global[chord("cmd+option+2")] == .windowsSelect(2))
    #expect(configuration.global.count == Defaults.global.count)
  }

  @Test func eachProblemNamesItsSettingAndTheRestApplies() {
    let configuration = resolve(
      """
      colour = "blue"

      [keymap.global]
      "ctrl+option+w" = "windows select 1"
      "ctrl+w+" = "windows select 1"
      "cmd+option+q" = "windows close"
      "fn+ctrl+f" = "windows arrange fill"
      "q" = "desktops new"
      "cmd+option+e" = 3

      [keymap.leader]
      "x" = "desktops new"
      "x t" = "desktops delete"
      "y" = 7
      """)
    #expect(
      configuration.problems.map(\.location) == [
        "colour", "keymap.global \"cmd+option+e\"", "keymap.leader \"y\"",
        "keymap.global \"ctrl+w+\"",
        "keymap.global \"cmd+option+q\"", "keymap.global \"fn+ctrl+f\"", "keymap.global \"q\"",
        "keymap.leader \"x t\"",
      ])
    #expect(configuration.problems[4].message.contains("not a command"))
    #expect(configuration.problems[7].message.contains("passes through \"x\""))
    #expect(configuration.global[chord("ctrl+option+w")] == .windowsSelect(1))
    #expect(command(configuration.menu, "x") == .desktopsNew)
  }

  @Test func aQueryCannotBeBoundToAKey() {
    let configuration = resolve(
      """
      [keymap.global]
      "ctrl+option+l" = "windows list"

      [keymap.leader]
      "x" = "config show"
      """)
    #expect(
      configuration.problems.map(\.location) == [
        "keymap.global \"ctrl+option+l\"", "keymap.leader \"x\"",
      ])
    #expect(configuration.problems[0].message.contains("is a query"))
    #expect(configuration.global[chord("ctrl+option+l")] == nil)
    #expect(command(configuration.menu, "x") == nil)
  }

  @Test func twoUserEntriesForOneKeyAreDiagnosed() {
    let configuration = resolve(
      """
      [keymap.global]
      "cmd+option+w" = "windows select 1"
      "option+command+w" = "windows select 2"

      [keymap.leader]
      "x a" = "desktops new"
      "X A" = "desktops delete"
      """)
    #expect(configuration.problems.count == 2)
    #expect(configuration.problems[0].location == "keymap.global \"option+command+w\"")
    #expect(
      configuration.problems[0].message == "is the same key as keymap.global \"cmd+option+w\"")
    #expect(configuration.problems[1].location == "keymap.leader \"X A\"")
    #expect(configuration.global[chord("cmd+option+w")] == .windowsSelect(1))
    #expect(command(submenu(configuration.menu, "x")!, "a") == .desktopsNew)
  }

  @Test func keysMacOSNeedsForSwitchingSpacesAreRefused() {
    let configuration = resolve(
      """
      [keymap.global]
      "ctrl+3" = "desktops select 3"
      """, spaceChords: [chord("ctrl+3"), chord("fn+ctrl+left")])
    #expect(configuration.problems.count == 1)
    #expect(configuration.problems[0].message.contains("macOS's own shortcut"))
    #expect(configuration.global[chord("ctrl+3")] == nil)
    // macOS reports Fn on its arrow shortcuts; the chord as written is the same key.
    let arrows = resolve(
      "[keymap.global]\n\"ctrl+left\" = \"spaces previous\"", spaceChords: [chord("fn+ctrl+left")])
    #expect(arrows.problems.count == 1)
    #expect(arrows.global[chord("ctrl+left")] == nil)
  }

  @Test func theLeaderKeyIsItsOwnAndDisplacesADefault() {
    let configuration = resolve(
      """
      [leader]
      key = "option+1"
      delay = 0.5
      timeout = false

      [keymap.global]
      "option+1" = "desktops select 4"
      """)
    #expect(
      configuration.leader
        == LeaderSettings(chord: chord("option+1"), delay: .milliseconds(500), timeout: nil))
    #expect(configuration.global[chord("option+1")] == nil)
    #expect(configuration.problems.map(\.text) == ["keymap.global \"option+1\": is the leader key"])
  }

  @Test func leaderAndWindowListSettingsAreCheckedOneByOne() {
    let configuration = resolve(
      """
      [leader]
      key = "unbind"
      delay = -1
      timeout = 0.01
      colour = 1

      [window-list]
      modifiers = "ctrl+shift"
      """)
    #expect(configuration.leader.chord == nil)
    // The setup page draws these as keycaps, and says so when there is no leader key.
    let report = ConfigReport(file: nil, configuration: configuration, rejection: nil)
    #expect(report.leaderKey == nil)
    #expect(report.leaderKeyPieces == nil)
    #expect(report.windowListModifiers == "⌃⇧")
    #expect(report.windowListModifierPieces == ["⌃", "⇧"])
    #expect(configuration.leader.delay == .zero)
    #expect(configuration.leader.timeout == .seconds(10))
    #expect(configuration.windowListModifiers == [.control, .shift])
    #expect(
      configuration.problems.map(\.location) == ["leader colour", "leader delay", "leader timeout"])
    #expect(
      resolve("[window-list]\nmodifiers = \"fn+cmd\"").problems.map(\.text) == [
        "window-list modifiers: cannot include fn"
      ])
    #expect(resolve("[leader]\ntimeout = 3").leader.timeout == .seconds(3))
    // TOML has inf and nan, which no Duration can hold.
    let unbounded = resolve("[leader]\ndelay = inf\ntimeout = nan")
    #expect(unbounded.leader == Defaults.leader)
    #expect(unbounded.problems.map(\.location) == ["leader delay", "leader timeout"])
    let taken = resolve("[leader]\nkey = \"ctrl+1\"", spaceChords: [chord("ctrl+1")])
    #expect(taken.leader.chord == Defaults.leader.chord)
    #expect(taken.problems.map(\.location) == ["leader key"])
    #expect(resolve("[leader]\nkey = \"fn+space\"").problems.map(\.location) == ["leader key"])
  }

  @Test func spaceListSettingsAreCheckedOneByOne() {
    let configuration = resolve(
      """
      [space-list]
      modifiers = "ctrl+option"
      delay = 0
      enabled = false
      """)
    #expect(configuration.problems.isEmpty)
    #expect(
      configuration.spaceList
        == SpaceListSettings(modifiers: [.control, .option], delay: .zero, isEnabled: false))
    let report = ConfigReport(file: nil, configuration: configuration, rejection: nil)
    #expect(report.text.contains("\nSpace list: off\n"))
    #expect(report.spaceListModifierPieces == nil)
    // Turning the list off, or moving it, leaves every shortcut as it was.
    #expect(configuration.global == resolve("").global)
    let immediate = resolve("[space-list]\ndelay = 0")
    #expect(
      ConfigReport(file: nil, configuration: immediate, rejection: nil).text.contains(
        "\nSpace list: hold ⌥; appears at once\n"))

    // A setting with a problem is left out, and the others apply.
    let wrong = resolve(
      """
      [space-list]
      modifiers = "fn+option"
      delay = -1
      enabled = "no"
      colour = 1
      """)
    #expect(wrong.spaceList == Defaults.spaceList)
    #expect(
      wrong.problems.map(\.text).sorted() == [
        "space-list colour: is not a space-list setting; the settings are modifiers, delay, and enabled",
        "space-list delay: must be a number of seconds, 0 or more",
        "space-list enabled: must be true or false",
        "space-list modifiers: cannot include fn",
      ])
    let mixed = resolve("[space-list]\nmodifiers = \"option+w\"\ndelay = 0.5")
    #expect(mixed.spaceList.modifiers == [.option])
    #expect(mixed.spaceList.delay == .milliseconds(500))
    #expect(mixed.problems.map(\.location) == ["space-list modifiers"])
    #expect(resolve("[space-list]\ndelay = inf").problems.map(\.location) == ["space-list delay"])
    #expect(resolve("space-list = 1").problems.map(\.location) == ["space-list"])
  }

  @Test func aDefaultOnAChordMacOSSwitchesSpacesWithIsLeftOut() {
    let configuration = resolve("", spaceChords: [chord("option+1"), chord("fn+ctrl+left")])
    #expect(configuration.problems.isEmpty)
    #expect(configuration.global[chord("option+1")] == nil)
    #expect(configuration.global[chord("option+2")] == .spacesSelect(2))
    #expect(configuration.global.count == Defaults.global.count - 1)
  }

  @Test func bindingsTheUserWroteOutlastTheDefaultsThatChanged() {
    let configuration = resolve(
      """
      [keymap.global]
      "option+1" = "desktops select 1"
      "option+2" = "unbind"
      "option+shift+1" = "windows select 1"

      [keymap.leader]
      "s 1" = "desktops select 1"

      [[quick-apps]]
      app = "Notes"
      shortcut = "option+shift+2"
      """)
    #expect(configuration.problems.isEmpty)
    #expect(configuration.global[chord("option+1")] == .desktopsSelect(1))
    #expect(configuration.global[chord("option+2")] == nil)
    #expect(configuration.global[chord("option+shift+1")] == .windowsSelect(1))
    #expect(configuration.global[chord("option+shift+2")] == .quickAppsToggle("Notes"))
    // What the file leaves alone takes the new defaults.
    #expect(configuration.global[chord("option+3")] == .spacesSelect(3))
    #expect(configuration.global[chord("option+shift+3")] == .spacesMoveTo(3))
    let spaces = submenu(configuration.menu, "s")!
    #expect(command(spaces, "1") == .desktopsSelect(1))
    #expect(command(spaces, "2") == .spacesSelect(2))
  }

  @Test func leaderSequencesReplaceNameAndUnbind() {
    let configuration = resolve(
      """
      [keymap.leader]
      "w f" = "desktops new"
      "x" = { menu = "Extras" }
      "x n" = "desktops new"
      "w" = { menu = "Fenster" }
      "c" = "unbind"
      "s" = "desktops delete"
      """)
    #expect(configuration.problems.isEmpty)
    #expect(keys(of: configuration.menu) == ["s", "w", "x"])
    let windows = submenu(configuration.menu, "w")!
    #expect(windows.label == "Fenster")
    #expect(command(windows, "f") == .desktopsNew)
    #expect(command(windows, "c") == .windowsArrange(.center))
    #expect(submenu(configuration.menu, "x")?.label == "Extras")
    #expect(command(submenu(configuration.menu, "x")!, "n") == .desktopsNew)
    // A command at a shipped submenu replaces the whole submenu.
    #expect(command(configuration.menu, "s") == .desktopsDelete)
  }

  @Test func sequencesUnderAnUnboundOrCommandPrefixAreProblems() {
    let configuration = resolve(
      """
      [keymap.leader]
      "c" = "unbind"
      "c x" = "desktops new"
      "y t" = "desktops new"
      "y" = "desktops delete"
      "w f c" = "desktops new"
      """)
    #expect(
      configuration.problems.map(\.text) == [
        "keymap.leader \"c x\": is under the unbound sequence \"c\"",
        "keymap.leader \"y\": is both a command and the start of another sequence",
        "keymap.leader \"w f c\": passes through \"w f\", which is a command; unbind that first",
      ])
    #expect(command(submenu(configuration.menu, "y")!, "t") == .desktopsNew)
    #expect(submenu(configuration.menu, "c") == nil)
  }

  @Test func quickAppsBindDirectlyWithOptionalKeys() {
    let configuration = resolve(
      """
      [[quick-apps]]
      app = "1Password"
      leader = "a p"
      shortcut = "ctrl+option+p"

      [[quick-apps]]
      app = "com.apple.Notes"
      size = { width = 900, height = 650 }

      [[quick-apps]]
      app = "/Applications/Ghostty.app"
      leader = "a g"
      """)
    #expect(configuration.problems.isEmpty)
    #expect(
      configuration.quickApps.map(\.app) == [
        "1Password", "com.apple.Notes", "/Applications/Ghostty.app",
      ])
    #expect(configuration.quickApps[0].leader == [chord("a"), chord("p")])
    #expect(configuration.quickApps[0].shortcut == chord("ctrl+option+p"))
    #expect(configuration.quickApps[1].leader == nil)
    #expect(configuration.quickApps[1].shortcut == nil)
    #expect(configuration.quickApps[1].size == QuickAppSettings.Size(width: 900, height: 650))
    #expect(configuration.global[chord("ctrl+option+p")] == .quickAppsToggle("1Password"))
    let apps = submenu(configuration.menu, "a")!
    #expect(apps.label == "Quick Apps")
    #expect(command(apps, "p") == .quickAppsToggle("1Password"))
    #expect(command(apps, "g") == .quickAppsToggle("/Applications/Ghostty.app"))
  }

  @Test func quickAppProblemsAreNamedByApp() {
    let configuration = resolve(
      """
      [[quick-apps]]
      app = "1Password"
      shortcut = "p"

      [[quick-apps]]
      app = "1Password"

      [[quick-apps]]
      colour = "red"

      [[quick-apps]]
      app = "Notes"
      size = { width = 0, height = 10 }
      leader = "a fn+n"
      """)
    #expect(
      configuration.problems.map(\.location) == [
        "quick-apps #3", "quick-apps \"Notes\" size", "quick-apps \"1Password\" shortcut",
        "quick-apps \"1Password\"", "quick-apps \"Notes\" leader",
      ])
    #expect(configuration.quickApps.map(\.app) == ["1Password", "Notes"])
    #expect(configuration.quickApps[0].shortcut == nil)
    #expect(configuration.quickApps[1].leader == nil)
  }

  @Test func theThemeIsSystemUnlessTheFileNamesAnother() {
    #expect(resolve("").theme == .system)
    for theme in [Theme.light, .dark, .system] {
      let configuration = resolve("theme = \"\(theme.rawValue)\"")
      #expect(configuration.theme == theme)
      #expect(configuration.problems.isEmpty)
    }
  }

  @Test(arguments: [
    ("\"Dark\"", "must be \"light\", \"dark\", or \"system\""),
    ("\"\"", "must be \"light\", \"dark\", or \"system\""), ("true", "must be text in quotes"),
  ])
  func aThemeThatIsNotOneOfTheThreeIsLeftOutAndTheRestApplies(value: String, message: String) {
    let configuration = resolve(
      """
      theme = \(value)

      [leader]
      delay = 1
      """)
    #expect(configuration.theme == .system)
    #expect(
      configuration.problems == [Problem(location: "theme", message: message)])
    #expect(configuration.leader.delay == .seconds(1))
  }

  @Test func aFileThatCannotBeParsedIsRejectedWithItsLine() {
    let result = Overrides.parse(
      """
      [keymap.global]
      "ctrl+option+w" = "windows select 1
      """)
    guard case .failure(let problem) = result else {
      Issue.record("A broken file was read")
      return
    }
    #expect(problem.location == "line 2")
    #expect(!problem.message.isEmpty)
    #expect(Overrides.parse("").map(\.problems) == .success([]))
  }

  @Test func theReportListsWhatIsInEffect() {
    let configuration = resolve(
      """
      [keymap.global]
      "cmd+option+1" = "unbind"
      "bad" = "desktops new"

      [[quick-apps]]
      app = "1Password"
      leader = "a p"
      """)
    let report = ConfigReport(file: nil, configuration: configuration, rejection: nil)
    let text = report.text
    #expect(text.contains("Problems:\n  keymap.global \"bad\": \"bad\" in \"bad\" is not a key"))
    #expect(
      text.contains(
        "\nTheme: system\nLeader: ⌥Space; appears at once; closes after 10 s of inactivity"))
    #expect(report.json.contains("\"theme\" : \"system\""))
    #expect(text.contains("Window list: hold ⌥⌘"))
    #expect(report.leaderKey == "⌥Space")
    #expect(report.leaderKeyPieces == ["⌥", "Space"])
    #expect(report.windowListModifiers == "⌥⌘")
    #expect(report.windowListModifierPieces == ["⌥", "⌘"])
    #expect(text.contains("  ⌥1        spaces select 1"))
    #expect(text.contains("  ⌥⇧1       spaces move to 1"))
    #expect(text.contains("Window list: hold ⌥⌘\nSpace list: hold ⌥; appears after 0.2 s\n"))
    #expect(report.spaceListModifierPieces == ["⌥"])
    #expect(
      report.json.replacing(" ", with: "").replacing("\n", with: "").contains(
        "\"spaceList\":{\"delay\":0.2,\"enabled\":true,\"modifiers\":\"option\"}"))
    // A label longer than its column is never cut short.
    let wide = resolve("[keymap.global]\n\"ctrl+option+shift+cmd+space\" = \"desktops new\"")
    #expect(
      ConfigReport(file: nil, configuration: wide, rejection: nil).text.contains(
        "  ⌃⌥⇧⌘Space  desktops new"))
    #expect(!text.contains("⌥⌘1 "))
    #expect(text.contains("  a       Quick Apps\n    p       quick-apps toggle 1Password"))
    #expect(text.contains("Quick Apps:\n  1Password  leader a p"))
    #expect(report.json.contains("\"key\" : \"option+1\""))
    #expect(report.json.contains("\"windowListModifiers\" : \"option+cmd\""))
    // Keys without a row in the menu are in effect, so they are listed, and marked.
    #expect(
      text.contains(
        "    h       windows arrange left\n    ←       windows arrange left  (not shown in the menu)"
      ))
    #expect(text.contains("      ⇧h      windows arrange left-quarters\n"))
    #expect(text.contains("    ⇧→      spaces move by 1  (not shown in the menu)"))
    #expect(report.json.replacing(" ", with: "").contains("\"hidden\":true,\n\"key\":\"left\""))
    #expect(report.json.contains("\"key\" : \"shift+h\""))
    #expect(
      report.json.components(separatedBy: "\"hidden\" : true").count - 1 == Self.directions.count)
  }
}
