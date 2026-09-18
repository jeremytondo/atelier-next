import MacOS

/// Something wrong in the configuration file: which setting, and what is
/// wrong with it. A setting with a problem is left out, and the rest apply.
public struct Problem: Hashable, Sendable, Error {
  /// The setting, such as `keymap.global "ctrl+w"`, or `line 12` for a file
  /// that could not be read at all.
  public let location: String
  public let message: String

  public var text: String { "\(location): \(message)" }
}

public struct LeaderSettings: Equatable, Sendable {
  /// Nil when the leader is unbound.
  var chord: Chord?
  /// Before the menu appears.
  public var delay: Duration
  /// Of inactivity before the leader closes; nil for never.
  public var timeout: Duration?
}

public struct QuickAppSettings: Equatable, Sendable {
  public struct Size: Equatable, Sendable {
    public let width: Int
    public let height: Int
  }

  /// The app as written: a name, bundle identifier, or path.
  public let app: String
  var leader: [Chord]?
  var shortcut: Chord?
  public var size: Size?
}

/// The leader menu: each key opens a submenu or runs a command.
struct Menu: Equatable, Sendable {
  var label: String
  /// True when nobody named the submenu, so its label is its key.
  var isLabelKey = false
  var entries: [MenuEntry]
}

enum MenuEntry: Equatable, Sendable {
  /// A hidden command runs like any other and has no row in the menu on
  /// screen. Only a shipped binding is ever hidden; one the user wrote shows.
  case command(Chord, Command, isHidden: Bool)
  case submenu(Chord, Menu)

  var chord: Chord {
    switch self {
    case .command(let chord, _, _), .submenu(let chord, _): chord
    }
  }
}

/// How Atelier's interface looks: forced light or dark, or whatever macOS is.
public enum Theme: String, Sendable {
  case light, dark, system
}

/// What Atelier goes by: the built-in defaults with the user's file applied
/// over them, and the problems found on the way.
struct Configuration: Equatable, Sendable {
  var theme: Theme
  var leader: LeaderSettings
  var windowListModifiers: Chord.Modifiers
  /// Every global shortcut and its command; an unbound key is simply absent.
  var global: [Chord: Command]
  var menu: Menu
  var quickApps: [QuickAppSettings]
  var problems: [Problem]
}
