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
    /// A command whose key works without a row in the menu on screen.
    case hidden(String)
  }

  typealias MenuDefault = (sequence: String, target: Target)

  static let leaderMenu: [MenuDefault] =
    [
      ("s", .menu("Spaces")),
      ("s n", .command("desktops new")),
      ("s d", .command("desktops delete")),
    ]
    + directions("s shift+", h: "spaces move by -1", l: "spaces move by 1")
    + [
      ("w", .menu("Windows")),
      ("w f", .command("windows arrange fill")),
      ("w c", .command("windows arrange center")),
    ]
    + directions(
      "w ", h: "windows arrange left", j: "windows arrange bottom", k: "windows arrange top",
      l: "windows arrange right")
    + [("w t", .menu("Top"))]
    + directions("w t ", h: "windows arrange top-left", l: "windows arrange top-right")
    + [("w b", .menu("Bottom"))]
    + directions("w b ", h: "windows arrange bottom-left", l: "windows arrange bottom-right")
    + [("w a", .menu("Arrange"))]
    + directions(
      "w a ", h: "windows arrange left-right", j: "windows arrange bottom-top",
      k: "windows arrange top-bottom", l: "windows arrange right-left")
    + directions(
      "w a shift+", h: "windows arrange left-quarters", j: "windows arrange bottom-quarters",
      k: "windows arrange top-quarters", l: "windows arrange right-quarters")
    + [
      ("w a q", .command("windows arrange quarters")),
      ("a", .menu("Quick Apps")),
      ("c", .menu("Configuration")),
      ("c o", .command("config open")),
      ("c r", .command("config reload")),
    ]
    + (1...10).map { number in ("s \(number % 10)", .command("desktops select \(number)")) }

  /// Each direction is bound twice after `prefix`: the Vim letter, which the
  /// menu shows, and the arrow, which works unseen. They are two bindings, so
  /// changing or unbinding one leaves the other as it was.
  private static func directions(
    _ prefix: String, h: String, j: String? = nil, k: String? = nil, l: String
  ) -> [MenuDefault] {
    [("h", "left", h), ("j", "down", j), ("k", "up", k), ("l", "right", l)]
      .flatMap { (letter, arrow, command: String?) -> [MenuDefault] in
        guard let command else { return [] }
        return [(prefix + letter, .command(command)), (prefix + arrow, .hidden(command))]
      }
  }

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
