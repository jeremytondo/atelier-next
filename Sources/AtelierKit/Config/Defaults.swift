import MacOS

/// What Atelier does with no configuration file. Written as the file would
/// write it, so the two are checked the same way; the tests confirm that every
/// line here parses.
enum Defaults {
  static let leader = LeaderSettings(
    chord: Chord([.option], "space"), delay: .zero, timeout: .seconds(10))

  static let windowListModifiers: Chord.Modifiers = [.command, .option]

  static let global: [(key: String, command: String)] =
    [
      ("ctrl+option+cmd+r", "config reload"),
      ("cmd+option+[", "windows cycle previous"),
      ("cmd+option+]", "windows cycle next"),
      ("cmd+option+shift+[", "windows move by -1"),
      ("cmd+option+shift+]", "windows move by 1"),
      ("option+`", "desktops new"),
      ("ctrl+option+left", "spaces move by -1"),
      ("ctrl+option+right", "spaces move by 1"),
      ("ctrl+option+delete", "desktops delete"),
    ]
    + (1...10).flatMap { number in
      let key = number % 10
      return [
        ("option+\(key)", "desktops select \(number)"),
        ("cmd+option+\(key)", "windows select \(number)"),
        ("cmd+option+shift+\(key)", "windows move to \(number)"),
      ]
    }

  enum Target: Equatable, Sendable {
    case command(String)
    case menu(String)
  }

  static let leaderMenu: [(sequence: String, target: Target)] =
    [
      ("s", .menu("Spaces")),
      ("s n", .command("desktops new")),
      ("s d", .command("desktops delete")),
      ("s shift+left", .command("spaces move by -1")),
      ("s shift+right", .command("spaces move by 1")),
      ("w", .menu("Windows")),
      ("w f", .command("windows arrange fill")),
      ("w c", .command("windows arrange center")),
      ("w left", .command("windows arrange left")),
      ("w right", .command("windows arrange right")),
      ("w up", .command("windows arrange top")),
      ("w down", .command("windows arrange bottom")),
      ("w t", .menu("Top")),
      ("w t l", .command("windows arrange top-left")),
      ("w t r", .command("windows arrange top-right")),
      ("w b", .menu("Bottom")),
      ("w b l", .command("windows arrange bottom-left")),
      ("w b r", .command("windows arrange bottom-right")),
      ("w a", .menu("Arrange")),
      ("w a left", .command("windows arrange left-right")),
      ("w a right", .command("windows arrange right-left")),
      ("w a up", .command("windows arrange top-bottom")),
      ("w a down", .command("windows arrange bottom-top")),
      ("w a shift+left", .command("windows arrange left-quarters")),
      ("w a shift+right", .command("windows arrange right-quarters")),
      ("w a shift+up", .command("windows arrange top-quarters")),
      ("w a shift+down", .command("windows arrange bottom-quarters")),
      ("w a q", .command("windows arrange quarters")),
      ("a", .menu("Quick Apps")),
      ("c", .menu("Configuration")),
      ("c o", .command("config open")),
      ("c r", .command("config reload")),
    ] + (1...10).map { number in ("s \(number % 10)", .command("desktops select \(number)")) }

  /// The file `config open` writes when there is none.
  static let fileTemplate = """
    # Atelier configuration. Atelier runs with built-in defaults; this file
    # overrides them. `atelier config show` prints what is in effect, and
    # `atelier config reload` applies your edits.
    #
    # [leader]
    # key = "option+space"
    # delay = 0
    # timeout = 10
    #
    # [window-list]
    # modifiers = "cmd+option"
    #
    # [keymap.global]
    # "ctrl+option+w" = "windows select 1"
    # "cmd+option+1" = "unbind"
    #
    # [keymap.leader]
    # "x" = { menu = "Extras" }
    # "x n" = "desktops new"
    #
    # [[quick-apps]]
    # app = "1Password"
    # leader = "a p"
    # shortcut = "ctrl+option+p"

    """
}
