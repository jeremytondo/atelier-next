import Foundation
import TOMLDecoder

/// What the user's file says, read but not yet checked against the defaults.
/// TOML the parser cannot read fails the whole file with its line; anything
/// else wrong is a problem with one setting, which is left out.
struct Overrides: Equatable, Sendable {
  enum LeaderTarget: Equatable, Sendable {
    case command(String)
    case menu(String)
    case unbind
  }

  struct Entry<Target: Equatable & Sendable>: Equatable, Sendable {
    var key: String
    var target: Target
    var location: String
  }

  struct QuickApp: Equatable, Sendable {
    var app: String
    var leader: String?
    var shortcut: String?
    var size: QuickAppSettings.Size?
    var location: String
  }

  var theme: String?
  var leaderKey: String?
  var leaderDelay: Double?
  /// `.some(nil)` for a leader that never times out.
  var leaderTimeout: Double??
  var windowListModifiers: String?
  var global: [Entry<String>] = []
  var leader: [Entry<LeaderTarget>] = []
  var quickApps: [QuickApp] = []
  var problems: [Problem] = []

  static func parse(_ text: String) -> Result<Overrides, Problem> {
    let root: TOMLTable
    do {
      root = try TOMLTable(source: text)
    } catch {
      return .failure(Self.problem(from: error))
    }
    var overrides = Overrides()
    for key in root.keys {
      switch key {
      case "theme": overrides.theme = overrides.string(root, key, at: key)
      case "leader": overrides.readLeader(root, key)
      case "window-list": overrides.readWindowList(root, key)
      case "keymap": overrides.readKeymap(root, key)
      case "quick-apps": overrides.readQuickApps(root, key)
      default: overrides.report(key, "is not a setting Atelier knows")
      }
    }
    return .success(overrides)
  }

  /// The parser says "(Line 12) ..." and that becomes the location.
  private static func problem(from error: TOMLError) -> Problem {
    let description = error.description
    if let match = description.firstMatch(of: #/^\(Line (\d+)\) /#) {
      return Problem(
        location: "line \(match.1)", message: String(description[match.range.upperBound...]))
    }
    return Problem(location: "file", message: description)
  }

  private mutating func report(_ location: String, _ message: String) {
    problems.append(Problem(location: location, message: message))
  }

  private mutating func readLeader(_ root: TOMLTable, _ key: String) {
    guard let table = table(root, key) else { return }
    for name in table.keys {
      let location = "leader \(name)"
      switch name {
      case "key": leaderKey = string(table, name, at: location)
      case "delay": leaderDelay = seconds(table, name, at: location)
      case "timeout":
        if (try? table.bool(forKey: name)) == false {
          leaderTimeout = .some(nil)
        } else if let value = seconds(table, name, at: location) {
          leaderTimeout = .some(value)
        }
      default: report(location, "is not a leader setting; the settings are key, delay, and timeout")
      }
    }
  }

  private mutating func readWindowList(_ root: TOMLTable, _ key: String) {
    guard let table = table(root, key) else { return }
    for name in table.keys {
      let location = "window-list \(name)"
      switch name {
      case "modifiers": windowListModifiers = string(table, name, at: location)
      default: report(location, "is not a window-list setting; the setting is modifiers")
      }
    }
  }

  private mutating func readKeymap(_ root: TOMLTable, _ key: String) {
    guard let keymap = table(root, key) else { return }
    for name in keymap.keys {
      switch name {
      case "global":
        guard let table = table(keymap, "global", in: "keymap") else { continue }
        for chord in table.keys {
          let location = "keymap.global \"\(chord)\""
          guard let value = try? table.string(forKey: chord) else {
            report(location, "must be a command such as \"windows select 1\", or \"unbind\"")
            continue
          }
          global.append(Entry(key: chord, target: value, location: location))
        }
      case "leader":
        guard let table = table(keymap, "leader", in: "keymap") else { continue }
        for sequence in table.keys {
          let location = "keymap.leader \"\(sequence)\""
          if let value = try? table.string(forKey: sequence) {
            leader.append(
              Entry(
                key: sequence, target: value == "unbind" ? .unbind : .command(value),
                location: location))
          } else if let menu = try? table.table(forKey: sequence),
            menu.keys == ["menu"], let label = try? menu.string(forKey: "menu")
          {
            leader.append(Entry(key: sequence, target: .menu(label), location: location))
          } else {
            report(
              location,
              "must be a command such as \"desktops new\", \"unbind\", or { menu = \"Name\" }")
          }
        }
      default: report("keymap.\(name)", "is not a keymap; the keymaps are global and leader")
      }
    }
  }

  private mutating func readQuickApps(_ root: TOMLTable, _ key: String) {
    guard let array = try? root.array(forKey: key) else {
      report("quick-apps", "must be a list of [[quick-apps]] tables")
      return
    }
    for index in 0..<array.count {
      var location = "quick-apps #\(index + 1)"
      guard let table = try? array.table(atIndex: index) else {
        report(location, "must be a [[quick-apps]] table")
        continue
      }
      guard let app = try? table.string(forKey: "app"),
        !app.trimmingCharacters(in: .whitespaces).isEmpty
      else {
        report(location, "needs an app: a name, bundle identifier, or path")
        continue
      }
      location = "quick-apps \"\(app)\""
      var entry = QuickApp(app: app.trimmingCharacters(in: .whitespaces), location: location)
      for name in table.keys {
        switch name {
        case "app": break
        case "leader": entry.leader = string(table, name, at: "\(location) leader")
        case "shortcut": entry.shortcut = string(table, name, at: "\(location) shortcut")
        case "size":
          guard let size = try? table.table(forKey: name),
            size.keys.sorted() == ["height", "width"],
            let width = try? size.integer(forKey: "width"),
            let height = try? size.integer(forKey: "height"), width > 0, height > 0
          else {
            report("\(location) size", "must be { width = 900, height = 650 } in points")
            continue
          }
          entry.size = QuickAppSettings.Size(width: Int(width), height: Int(height))
        default:
          report(
            "\(location) \(name)",
            "is not a Quick App setting; they are app, leader, shortcut, and size")
        }
      }
      quickApps.append(entry)
    }
  }

  private mutating func table(_ parent: TOMLTable, _ key: String, in path: String? = nil)
    -> TOMLTable?
  {
    guard let table = try? parent.table(forKey: key) else {
      report(path.map { "\($0).\(key)" } ?? key, "must be a table, written as [\(key)]")
      return nil
    }
    return table
  }

  private mutating func string(_ table: TOMLTable, _ key: String, at location: String) -> String? {
    guard let value = try? table.string(forKey: key) else {
      report(location, "must be text in quotes")
      return nil
    }
    return value
  }

  private mutating func seconds(_ table: TOMLTable, _ key: String, at location: String) -> Double? {
    if let value = try? table.float(forKey: key) { return value }
    if let value = try? table.integer(forKey: key) { return Double(value) }
    report(location, "must be a number of seconds")
    return nil
  }
}
