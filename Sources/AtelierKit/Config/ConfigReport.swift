import Foundation
import MacOS

/// A configuration as `config show` and `config check` describe it.
public struct ConfigReport: Sendable {
  let file: URL?
  let configuration: Configuration
  /// Why the file was refused, if it was.
  public let rejection: Problem?

  public var problems: [Problem] {
    configuration.problems + (rejection.map { [$0] } ?? [])
  }

  /// The leader key as the HUD writes keys, such as ⌥Space; nil when unbound.
  public var leaderKey: String? { configuration.leader.chord.map(KeyGrammar.describe) }

  /// The modifiers that show the window list while held, such as ⌥⌘.
  public var windowListModifiers: String {
    KeyGrammar.describe(configuration.windowListModifiers)
  }

  /// The file as a person would write it, with `~` for the home folder.
  public var filePath: String? {
    file.map { ($0.path as NSString).abbreviatingWithTildeInPath }
  }

  public var text: String {
    var lines: [String] = []
    if let file, FileManager.default.fileExists(atPath: file.path) {
      lines.append("File: \(file.path)")
    } else {
      lines.append("File: none at \(file?.path ?? "any path"); the built-in defaults are in effect")
    }
    if !problems.isEmpty {
      lines.append("Problems:")
      lines += problems.map { "  \($0.text)" }
    }
    lines.append("Theme: \(configuration.theme.rawValue)")
    let leader = configuration.leader
    let shows =
      leader.delay == .zero ? "appears at once" : "appears after \(Self.seconds(leader.delay))"
    let closes =
      leader.timeout.map { "closes after \(Self.seconds($0)) of inactivity" }
      ?? "never closes on its own"
    lines.append(
      "Leader: \(leader.chord.map(KeyGrammar.describe) ?? "unbound"); \(shows); \(closes)")
    lines.append("Window list: hold \(KeyGrammar.describe(configuration.windowListModifiers))")
    lines.append("Shortcuts:")
    lines += configuration.global.map { (KeyGrammar.describe($0.key), $0.value.words) }
      .sorted { $0.0 < $1.0 }.map { "  \(Self.column($0.0, 8))  \($0.1)" }
    lines.append("Leader menu:")
    lines += Self.lines(of: configuration.menu, indent: "  ")
    if configuration.quickApps.isEmpty {
      lines.append("Quick Apps: none")
    } else {
      lines.append("Quick Apps:")
      lines += configuration.quickApps.map { app in
        var parts = [app.app]
        if let leader = app.leader { parts.append("leader \(KeyGrammar.describe(leader))") }
        if let shortcut = app.shortcut { parts.append("shortcut \(KeyGrammar.describe(shortcut))") }
        if let size = app.size { parts.append("\(size.width) × \(size.height)") }
        return "  " + parts.joined(separator: "  ")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func lines(of menu: Menu, indent: String) -> [String] {
    menu.entries.flatMap { entry -> [String] in
      switch entry {
      case .command(let chord, let command, let isHidden):
        [
          "\(indent)\(Self.column(KeyGrammar.describe(chord), 6))  \(command.words)"
            + (isHidden ? "  (not shown in the menu)" : "")
        ]
      case .submenu(let chord, let submenu):
        [
          "\(indent)\(Self.column(KeyGrammar.describe(chord), 6))  \(submenu.label)"
        ]
          + lines(of: submenu, indent: indent + "  ")
      }
    }
  }

  /// Padded to the column, never cut short.
  private static func column(_ text: String, _ width: Int) -> String {
    text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
  }

  private static func seconds(_ duration: Duration) -> String {
    let seconds =
      Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    return seconds == seconds.rounded() ? "\(Int(seconds)) s" : "\(seconds) s"
  }

  public var json: String {
    struct Payload: Encodable {
      struct ProblemItem: Encodable {
        var location: String
        var message: String
      }
      struct Leader: Encodable {
        var key: String?
        var delay: Double
        var timeout: Double?
      }
      struct Shortcut: Encodable {
        var key: String
        var command: String
      }
      struct Entry: Encodable {
        var key: String
        var command: String?
        var menu: String?
        /// Present, and true, for a key that works without a row in the menu.
        var hidden: Bool?
        var entries: [Entry]?
      }
      struct QuickApp: Encodable {
        struct Size: Encodable {
          var width: Int
          var height: Int
        }
        var app: String
        var leader: String?
        var shortcut: String?
        var size: Size?
      }
      var file: String?
      var problems: [ProblemItem]
      var theme: String
      var leader: Leader
      var windowListModifiers: String
      var shortcuts: [Shortcut]
      var menu: [Entry]
      var quickApps: [QuickApp]
    }
    func entries(_ menu: Menu) -> [Payload.Entry] {
      menu.entries.map { entry in
        switch entry {
        case .command(let chord, let command, let isHidden):
          Payload.Entry(
            key: KeyGrammar.text(chord), command: command.words, hidden: isHidden ? true : nil)
        case .submenu(let chord, let submenu):
          Payload.Entry(key: KeyGrammar.text(chord), menu: submenu.label, entries: entries(submenu))
        }
      }
    }
    let leader = configuration.leader
    return encoded(
      Payload(
        file: file?.path,
        problems: problems.map { Payload.ProblemItem(location: $0.location, message: $0.message) },
        theme: configuration.theme.rawValue,
        leader: Payload.Leader(
          key: leader.chord.map(KeyGrammar.text), delay: Self.number(leader.delay),
          timeout: leader.timeout.map(Self.number)),
        windowListModifiers: KeyGrammar.text(configuration.windowListModifiers),
        shortcuts: configuration.global.map {
          Payload.Shortcut(key: KeyGrammar.text($0.key), command: $0.value.words)
        }.sorted { $0.key < $1.key },
        menu: entries(configuration.menu),
        quickApps: configuration.quickApps.map { app in
          Payload.QuickApp(
            app: app.app, leader: app.leader.map(KeyGrammar.text),
            shortcut: app.shortcut.map(KeyGrammar.text),
            size: app.size.map { Payload.QuickApp.Size(width: $0.width, height: $0.height) })
        }))
  }

  private static func number(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}

extension ReloadResult {
  var text: String {
    let done = outcome == .changed ? "Reloaded." : "Reloaded; nothing had changed."
    guard !problems.isEmpty else { return done }
    return ([done + " Problems:"] + problems.map { "  \($0.text)" }).joined(separator: "\n")
  }

  var json: String {
    struct Payload: Encodable {
      struct ProblemItem: Encodable {
        var location: String
        var message: String
      }
      var outcome: String
      var problems: [ProblemItem]
    }
    return encoded(
      Payload(
        outcome: "\(outcome)",
        problems: problems.map { Payload.ProblemItem(location: $0.location, message: $0.message) }))
  }
}

func encoded(_ payload: some Encodable) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: (try? encoder.encode(payload)) ?? Data(), as: UTF8.self)
}
