import MacOS

/// Everything Atelier can be asked, one case per request, parsed from the
/// words the `atelier` command takes, such as `windows select 1`. A key in the
/// configuration names its command with the same words, so the terminal, a
/// shortcut, and the leader menu all reach the same thing, and a binding can
/// be checked without running it.
package enum Command: Hashable, Sendable {
  case windowsList
  case windowsSelect(Int)
  case windowsCycle(CycleDirection)
  case windowsMove(WindowMove)
  case windowsArrange(Arrangement)
  case spacesList
  case spacesNext
  case spacesPrevious
  case spacesSelect(Int)
  case spacesMove(from: Int, to: Int)
  case spacesMoveBy(Int)
  case desktopsNew
  case desktopsSelect(Int)
  case desktopsDelete
  case quickAppsList
  case quickAppsToggle(String)
  case configShow
  case configCheck
  case configOpen
  case configReload
  case doctor
  case quit

  /// Nil for a name or arguments Atelier does not know.
  package init?(name: String, arguments: [String]) {
    let number = arguments.count == 1 ? Int(arguments[0]) : nil
    let second = arguments.count == 2 ? Int(arguments[1]) : nil
    switch (name, arguments.first, arguments.count) {
    case ("windows.list", nil, _): self = .windowsList
    case ("windows.select", _, 1):
      guard let number else { return nil }
      self = .windowsSelect(number)
    case ("windows.cycle", "next", 1): self = .windowsCycle(.next)
    case ("windows.cycle", "previous", 1): self = .windowsCycle(.previous)
    case ("windows.move", "by", 2):
      guard let second else { return nil }
      self = .windowsMove(.by(second))
    case ("windows.move", "to", 2):
      guard let second else { return nil }
      self = .windowsMove(.toSlot(second))
    case ("windows.arrange", _, 1):
      guard let arrangement = Arrangement(rawValue: arguments[0]) else { return nil }
      self = .windowsArrange(arrangement)
    case ("spaces.list", nil, _): self = .spacesList
    case ("spaces.next", nil, _): self = .spacesNext
    case ("spaces.previous", nil, _): self = .spacesPrevious
    case ("spaces.select", _, 1):
      guard let number else { return nil }
      self = .spacesSelect(number)
    case ("spaces.move", "by", 2):
      guard let second else { return nil }
      self = .spacesMoveBy(second)
    case ("spaces.move", _, 2):
      guard let from = Int(arguments[0]), let second else { return nil }
      self = .spacesMove(from: from, to: second)
    case ("desktops.new", nil, _): self = .desktopsNew
    case ("desktops.select", _, 1):
      guard let number else { return nil }
      self = .desktopsSelect(number)
    case ("desktops.delete", nil, _): self = .desktopsDelete
    case ("quick-apps.list", nil, _): self = .quickAppsList
    case ("quick-apps.toggle", .some, _): self = .quickAppsToggle(arguments.joined(separator: " "))
    case ("config.show", nil, _): self = .configShow
    case ("config.check", nil, _): self = .configCheck
    case ("config.open", nil, _): self = .configOpen
    case ("config.reload", nil, _): self = .configReload
    case ("doctor", nil, _): self = .doctor
    case ("quit", nil, _): self = .quit
    default: return nil
    }
  }

  /// From the words as the terminal takes them, such as `windows select 1`,
  /// or `quit`, which stands alone.
  package init?(words: String) {
    let parts = words.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let first = parts.first else { return nil }
    if parts.count == 1 {
      self.init(name: first, arguments: [])
    } else {
      self.init(name: "\(first).\(parts[1])", arguments: Array(parts.dropFirst(2)))
    }
  }

  package var name: String {
    switch self {
    case .windowsList: "windows.list"
    case .windowsSelect: "windows.select"
    case .windowsCycle: "windows.cycle"
    case .windowsMove: "windows.move"
    case .windowsArrange: "windows.arrange"
    case .spacesList: "spaces.list"
    case .spacesNext: "spaces.next"
    case .spacesPrevious: "spaces.previous"
    case .spacesSelect: "spaces.select"
    case .spacesMove, .spacesMoveBy: "spaces.move"
    case .desktopsNew: "desktops.new"
    case .desktopsSelect: "desktops.select"
    case .desktopsDelete: "desktops.delete"
    case .quickAppsList: "quick-apps.list"
    case .quickAppsToggle: "quick-apps.toggle"
    case .configShow: "config.show"
    case .configCheck: "config.check"
    case .configOpen: "config.open"
    case .configReload: "config.reload"
    case .doctor: "doctor"
    case .quit: "quit"
    }
  }

  package var arguments: [String] {
    switch self {
    case .windowsList, .spacesList, .spacesNext, .spacesPrevious, .desktopsNew, .desktopsDelete,
      .quickAppsList, .configShow, .configCheck, .configOpen, .configReload, .doctor, .quit:
      []
    case .windowsSelect(let slot): ["\(slot)"]
    case .windowsCycle(.next): ["next"]
    case .windowsCycle(.previous): ["previous"]
    case .windowsMove(.by(let offset)): ["by", "\(offset)"]
    case .windowsMove(.toSlot(let slot)): ["to", "\(slot)"]
    case .windowsArrange(let arrangement): [arrangement.rawValue]
    case .spacesSelect(let position): ["\(position)"]
    case .spacesMove(let from, let to): ["\(from)", "\(to)"]
    case .spacesMoveBy(let offset): ["by", "\(offset)"]
    case .desktopsSelect(let number): ["\(number)"]
    case .quickAppsToggle(let app): [app]
    }
  }

  /// The command as the terminal would take it: `windows select 1`.
  package var words: String {
    ([name.replacingOccurrences(of: ".", with: " ")] + arguments).joined(separator: " ")
  }

  /// A query answers; it has nothing to do for a key.
  package var isQuery: Bool {
    switch self {
    case .windowsList, .spacesList, .quickAppsList, .configShow, .configCheck, .doctor: true
    default: false
    }
  }

  /// What a menu calls it.
  package var label: String {
    switch self {
    case .windowsList: "Window List"
    case .windowsSelect(let slot): "Window \(slot)"
    case .windowsCycle(.next): "Next Window"
    case .windowsCycle(.previous): "Previous Window"
    case .windowsMove(.by(1)): "Move Later"
    case .windowsMove(.by(-1)): "Move Earlier"
    case .windowsMove(.by(let offset)):
      offset > 0 ? "Move \(offset) Later" : "Move \(-offset) Earlier"
    case .windowsMove(.toSlot(let slot)): "Move to \(slot)"
    case .windowsArrange(let arrangement): arrangement.label
    case .spacesList: "Space List"
    case .spacesNext: "Next Space"
    case .spacesPrevious: "Previous Space"
    case .spacesSelect(let position): "Space \(position)"
    case .spacesMove(let from, let to): "Move Space \(from) to \(to)"
    case .spacesMoveBy(1): "Move Space Later"
    case .spacesMoveBy(-1): "Move Space Earlier"
    case .spacesMoveBy(let offset):
      offset > 0 ? "Move Space \(offset) Later" : "Move Space \(-offset) Earlier"
    case .desktopsNew: "New Desktop"
    case .desktopsSelect(let number): "Desktop \(number)"
    case .desktopsDelete: "Delete Desktop"
    case .quickAppsList: "Quick App List"
    case .quickAppsToggle(let app): app
    case .configShow: "Show Configuration"
    case .configCheck: "Check Configuration"
    case .configOpen: "Open Configuration"
    case .configReload: "Reload Configuration"
    case .doctor: "Doctor"
    case .quit: "Quit Atelier"
    }
  }
}
