import MacOS

/// Lays the user's overrides over the defaults. A user entry at a key
/// replaces the default there, `unbind` removes it, and an entry with a
/// problem is left out with the problem recorded. Two user entries for one
/// key, a sequence that would pass through a command, and a key macOS needs
/// for itself are problems too.
enum Keymap {
  static func resolve(_ overrides: Overrides, spaceShortcuts: Set<Chord>) -> Configuration {
    // macOS lists Fn on its arrow-key shortcuts, which no configured chord carries.
    let spaceShortcuts = Set(
      spaceShortcuts.map { Chord($0.modifiers.subtracting(.function), $0.key) })
    var resolver = Resolver(problems: overrides.problems, spaceShortcuts: spaceShortcuts)
    let leader = resolver.leader(overrides)
    let windowList = resolver.windowListModifiers(overrides)
    var (global, quickApps) = resolver.global(overrides, leader: leader.chord)
    let menu = resolver.menu(overrides, quickApps: &quickApps)
    return Configuration(
      leader: leader, windowListModifiers: windowList, global: global, menu: menu,
      quickApps: quickApps, problems: resolver.problems)
  }

  private struct Resolver {
    var problems: [Problem]
    let spaceShortcuts: Set<Chord>

    mutating func report(_ location: String, _ message: String) {
      problems.append(Problem(location: location, message: message))
    }

    mutating func leader(_ overrides: Overrides) -> LeaderSettings {
      var leader = Defaults.leader
      if let text = overrides.leaderKey {
        if text == "unbind" {
          leader.chord = nil
        } else {
          do {
            let chord = try KeyGrammar.chord(text)
            if chord.modifiers.contains(.function) {
              report("leader key", "cannot use fn")
            } else if spaceShortcuts.contains(chord) {
              report("leader key", "is macOS's own shortcut for switching Spaces")
            } else {
              leader.chord = chord
            }
          } catch {
            report("leader key", error.message)
          }
        }
      }
      // A day is plenty, and far short of what `Duration` could not hold.
      if let delay = overrides.leaderDelay {
        if delay >= 0, delay <= 86400 {
          leader.delay = .seconds(delay)
        } else {
          report("leader delay", "must be a number of seconds, 0 or more")
        }
      }
      if let timeout = overrides.leaderTimeout {
        if let seconds = timeout, !(seconds >= 0.1 && seconds <= 86400) {
          report("leader timeout", "must be at least 0.1 seconds, or false to never close")
        } else {
          leader.timeout = timeout.map { .seconds($0) }
        }
      }
      return leader
    }

    mutating func windowListModifiers(_ overrides: Overrides) -> Chord.Modifiers {
      guard let text = overrides.windowListModifiers else { return Defaults.windowListModifiers }
      do {
        let modifiers = try KeyGrammar.modifiers(text)
        guard !modifiers.contains(.function) else {
          report("window-list modifiers", "cannot include fn")
          return Defaults.windowListModifiers
        }
        return modifiers
      } catch {
        report("window-list modifiers", error.message)
        return Defaults.windowListModifiers
      }
    }

    mutating func global(_ overrides: Overrides, leader: Chord?) -> (
      [Chord: Command], [QuickAppSettings]
    ) {
      var global = Dictionary(
        uniqueKeysWithValues: Defaults.global.map {
          (try! KeyGrammar.chord($0.key), Command(words: $0.command)!)
        })
      var owners: [Chord: String] = [:]

      /// Binds the chord to the command, or to nothing, when everything
      /// about it is right, and says which chord.
      func claim(_ text: String, _ command: Command?, at location: String) -> Chord? {
        let chord: Chord
        do { chord = try KeyGrammar.chord(text) } catch {
          report(location, error.message)
          return nil
        }
        if chord.modifiers.contains(.function) {
          report(location, "shortcuts with fn are not supported")
          return nil
        }
        if let owner = owners[chord] {
          report(location, "is the same key as \(owner)")
          return nil
        }
        owners[chord] = location
        if chord == leader {
          report(location, "is the leader key")
          return nil
        }
        if spaceShortcuts.contains(chord) {
          report(
            location,
            "is macOS's own shortcut for switching Spaces, which Atelier presses itself; leave it to macOS"
          )
          return nil
        }
        global[chord] = command
        return chord
      }

      for entry in overrides.global {
        if entry.target == "unbind" {
          _ = claim(entry.key, nil, at: entry.location)
        } else if let command = Command(words: entry.target), command.isQuery {
          report(entry.location, "\"\(entry.target)\" is a query, which a key has nowhere to show")
        } else if let command = Command(words: entry.target) {
          _ = claim(entry.key, command, at: entry.location)
        } else {
          report(
            entry.location,
            "\"\(entry.target)\" is not a command; write it as the atelier command takes it, such as \"windows select 1\""
          )
        }
      }
      var quickApps: [QuickAppSettings] = []
      var seen: Set<String> = []
      for app in overrides.quickApps {
        guard seen.insert(app.app).inserted else {
          report(app.location, "is listed twice")
          continue
        }
        var settings = QuickAppSettings(app: app.app, size: app.size)
        if let shortcut = app.shortcut {
          settings.shortcut = claim(
            shortcut, .quickAppsToggle(app.app), at: "\(app.location) shortcut")
        }
        quickApps.append(settings)
      }
      if let leader { global[leader] = nil }
      return (global, quickApps)
    }

    private struct Mapping {
      enum Target {
        case command(Command)
        case menu(String)
        case unbind
      }
      let chords: [Chord]
      let target: Target
      let isUser: Bool
      /// A shipped binding that works without a row in the menu on screen.
      var isHidden = false
      let location: String
    }

    private final class Node {
      var label: String
      /// Until a mapping names the place, its label is its key.
      var isLabelKey = true
      var command: Command?
      var isHidden = false
      var children: [Chord: Node] = [:]
      var order: [Chord] = []

      init(label: String) {
        self.label = label
      }

      /// Whether a command is bound here or anywhere under here.
      var hasBindings: Bool {
        command != nil || children.values.contains(where: \.hasBindings)
      }

      func child(_ chord: Chord) -> Node {
        if let child = children[chord] { return child }
        let child = Node(label: KeyGrammar.describe(chord))
        children[chord] = child
        order.append(chord)
        return child
      }
    }

    /// The leader menu in three steps: the user's sequences are parsed and
    /// checked against each other; then every default and user mapping is
    /// laid into one tree in order, a default binding nothing where a user
    /// entry replaced or unbound it; then places with nothing bound under
    /// them are left out.
    mutating func menu(_ overrides: Overrides, quickApps: inout [QuickAppSettings]) -> Menu {
      var users: [Mapping] = []
      var claimed: [[Chord]: String] = [:]
      func claim(_ text: String, _ target: Mapping.Target, at location: String) -> [Chord]? {
        let chords: [Chord]
        do { chords = try KeyGrammar.sequence(text) } catch {
          report(location, error.message)
          return nil
        }
        if let owner = claimed[chords] {
          report(location, "is the same sequence as \(owner)")
          return nil
        }
        claimed[chords] = location
        users.append(Mapping(chords: chords, target: target, isUser: true, location: location))
        return chords
      }
      for entry in overrides.leader {
        switch entry.target {
        case .unbind: _ = claim(entry.key, .unbind, at: entry.location)
        case .menu(let label): _ = claim(entry.key, .menu(label), at: entry.location)
        case .command(let words):
          guard let command = Command(words: words) else {
            report(
              entry.location,
              "\"\(words)\" is not a command; write it as the atelier command takes it, such as \"desktops new\""
            )
            continue
          }
          guard !command.isQuery else {
            report(entry.location, "\"\(words)\" is a query, which a key has nowhere to show")
            continue
          }
          _ = claim(entry.key, .command(command), at: entry.location)
        }
      }
      for index in quickApps.indices {
        guard
          let text = overrides.quickApps.first(where: { $0.app == quickApps[index].app })?.leader
        else { continue }
        quickApps[index].leader = claim(
          text, .command(.quickAppsToggle(quickApps[index].app)),
          at: "quick-apps \"\(quickApps[index].app)\" leader")
      }

      // A user entry at a sequence replaces the default there. Every default
      // still reserves its place, so the menu keeps its order when a default
      // is replaced; a place with nothing bound under it is left out at the end.
      let defaults = Defaults.leaderMenu.map { entry in
        let target: Mapping.Target =
          switch entry.target {
          case .command(let words), .hidden(let words): .command(Command(words: words)!)
          case .menu(let label): .menu(label)
          }
        var isHidden = false
        if case .hidden = entry.target { isHidden = true }
        return Mapping(
          chords: try! KeyGrammar.sequence(entry.sequence), target: target, isUser: false,
          isHidden: isHidden, location: "")
      }

      let unbound = users.filter { if case .unbind = $0.target { true } else { false } }
        .map(\.chords)
      let replaced = users.filter { if case .command = $0.target { true } else { false } }
        .map(\.chords)
      let root = Node(label: "Atelier")
      root.isLabelKey = false
      mappings: for mapping in defaults + users {
        var binds = true
        if case .unbind = mapping.target { binds = false }
        if binds, let prefix = unbound.first(where: { mapping.chords.starts(with: $0) }) {
          if mapping.isUser {
            report(
              mapping.location, "is under the unbound sequence \"\(KeyGrammar.text(prefix))\"")
            continue
          }
          binds = false
        }
        if !mapping.isUser,
          claimed[mapping.chords] != nil
            || replaced.contains(where: {
              mapping.chords.count > $0.count && mapping.chords.starts(with: $0)
            })
        {
          binds = false
        }
        var node = root
        for (index, chord) in mapping.chords.enumerated() {
          let child = node.child(chord)
          let isLast = index == mapping.chords.count - 1
          if !binds {
            node = child
            continue
          }
          if !isLast {
            if child.command != nil {
              if mapping.isUser {
                report(
                  mapping.location,
                  "passes through \"\(KeyGrammar.text(Array(mapping.chords[...index])))\", which is a command; unbind that first"
                )
              }
              continue mappings
            }
          } else {
            switch mapping.target {
            case .command(let command):
              guard !child.hasBindings else {
                report(mapping.location, "is both a command and the start of another sequence")
                continue mappings
              }
              child.command = command
              child.isHidden = mapping.isHidden
            case .menu(let label):
              guard child.command == nil else {
                report(mapping.location, "names a submenu at a key that runs a command")
                continue mappings
              }
              child.label = label
              child.isLabelKey = false
            case .unbind: break
            }
          }
          node = child
        }
      }
      return build(root)
    }

    /// A submenu with nothing bound under it is not shown and not a key.
    private func build(_ node: Node) -> Menu {
      Menu(
        label: node.label, isLabelKey: node.isLabelKey,
        entries: node.order.compactMap { chord in
          let child = node.children[chord]!
          if let command = child.command {
            return .command(chord, command, isHidden: child.isHidden)
          }
          return child.hasBindings ? .submenu(chord, build(child)) : nil
        })
    }
  }
}
