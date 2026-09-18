import Client
import Foundation

/// Routes each request from outside the app, by its name and arguments, to
/// the same command or query the interface uses, and words the answer, so
/// every client says the same thing.
extension Atelier {
  package func reply(to request: Request) async -> Reply {
    guard let command = Command(name: request.name, arguments: request.arguments) else {
      return Reply(
        ok: false, output: "Atelier has no request \(request.name) that takes those arguments.")
    }
    do {
      return Reply(ok: true, output: try await answer(command, json: request.json))
    } catch {
      return Reply(ok: false, output: error.message)
    }
  }

  private func answer(_ command: Command, json: Bool) async throws(AtelierError) -> String {
    switch command {
    case .windowsList:
      let list = try await windows.list()
      return json ? list.json : list.text
    case .spacesList:
      let list = try await spaces.list()
      return json ? list.json : list.text
    case .configShow:
      let report = await config.show()
      return json ? report.json : report.text
    case .configCheck:
      let report = await config.check()
      guard report.problems.isEmpty else {
        throw .failed(
          json
            ? report.json
            : (["The configuration has problems:"] + report.problems.map { "  \($0.text)" })
              .joined(separator: "\n"))
      }
      return json ? report.json : "The configuration is valid."
    case .configReload:
      let result = try await config.reload()
      return json ? result.json : result.text
    case .quickAppsList:
      let list = await quickApps.list()
      return json ? list.json : list.text
    default:
      let outcome = try await perform(command)
      return json
        ? #"{"outcome": "\#(outcome)"}"# : outcome == .changed ? "Done." : "Nothing to do."
    }
  }

  /// Runs a command for a key. A query has nothing to show a key, so it is
  /// nothing to do.
  package func perform(_ command: Command) async throws(AtelierError) -> Outcome {
    try await runner.perform(command)
  }
}

/// Runs a command for whoever holds one: the router for the terminal, a
/// shortcut, or the leader menu.
struct CommandRunner: Sendable {
  let windows: Windows
  let spaces: Spaces
  let desktops: Desktops
  let config: Config
  let notices: Notices
  let quickApps: QuickApps

  func perform(_ command: Command) async throws(AtelierError) -> Outcome {
    switch command {
    case .windowsSelect(let slot): return try await windows.select(slot)
    case .windowsCycle(let direction): return try await windows.cycle(direction)
    case .windowsMove(let move): return try await windows.move(move)
    case .windowsArrange(let arrangement): return try await windows.arrange(arrangement)
    case .spacesNext: return try await spaces.next()
    case .spacesPrevious: return try await spaces.previous()
    case .spacesSelect(let position): return try await spaces.select(position: position)
    case .spacesMove(let from, let to): return try await spaces.move(from: from, to: to)
    case .spacesMoveBy(let offset): return try await spaces.move(by: offset)
    case .desktopsNew: return try await desktops.new()
    case .desktopsSelect(let number): return try await desktops.select(number: number)
    case .desktopsDelete: return try await desktops.delete()
    case .quickAppsToggle(let app): return try await quickApps.toggle(app)
    case .configOpen: return try await config.open()
    case .configReload:
      // From a key there is no reply to read, so problems become a notice.
      let result = try await config.reload()
      if !result.problems.isEmpty {
        notices.post(
          "Reloaded with \(result.problems.count) problem\(result.problems.count == 1 ? "" : "s"); see atelier config show."
        )
      }
      return result.outcome
    case .windowsList, .spacesList, .quickAppsList, .configShow, .configCheck: return .unchanged
    }
  }
}

extension SpaceList {
  var text: String {
    spaces.enumerated().map { index, space in
      let kind = space.desktopNumber.map { "Desktop \($0)" } ?? "Full screen or Split View"
      return "\(space.isCurrent ? "*" : " ") \(index + 1)  \(kind)  (\(space.id))"
    }.joined(separator: "\n")
  }

  var json: String {
    struct Payload: Encodable {
      struct Item: Encodable {
        var id: UInt64
        var position: Int
        var desktopNumber: Int?
        var current: Bool
      }
      var display: String
      var spaces: [Item]
    }
    return encoded(
      Payload(
        display: display,
        spaces: spaces.enumerated().map { index, space in
          Payload.Item(
            id: space.id, position: index + 1, desktopNumber: space.desktopNumber,
            current: space.isCurrent)
        }))
  }
}

extension WindowList {
  public static let notDesktopMessage =
    "The current Space is a full-screen or Split View Space, not a Desktop."

  var text: String {
    guard case .desktop(let windows, _) = self else { return Self.notDesktopMessage }
    guard !windows.isEmpty else { return "No windows on this Desktop." }
    return windows.map { window in
      let mark = window.isFocused ? "*" : " "
      let title = window.title.isEmpty ? window.app : "\(window.app) — \(window.title)"
      return "\(mark) \(window.id)  \(title)\(window.isVisible ? "" : "  (minimized or hidden)")"
    }.joined(separator: "\n")
  }

  var json: String {
    struct Payload: Encodable {
      struct Item: Encodable {
        var id: UInt32
        var app: String
        var title: String
        var focused: Bool
        var visible: Bool
      }
      var space: String
      var windows: [Item]
    }
    let payload =
      switch self {
      case .desktop(let windows, _):
        Payload(
          space: "desktop",
          windows: windows.map {
            Payload.Item(
              id: $0.id, app: $0.app, title: $0.title, focused: $0.isFocused,
              visible: $0.isVisible)
          })
      case .notDesktop: Payload(space: "notDesktop", windows: [])
      }
    return encoded(payload)
  }
}

extension [QuickAppInfo] {
  var text: String {
    guard !isEmpty else { return "No Quick Apps are configured. Add one under [[quick-apps]]." }
    return map { info in
      var parts = [(info.isShown ? "* " : "  ") + info.app]
      if let name = info.name, name != info.app { parts.append("(\(name))") }
      if let leader = info.leader { parts.append("leader \(leader)") }
      if let shortcut = info.shortcut { parts.append("shortcut \(shortcut)") }
      if let problem = info.problem { parts.append(problem) }
      return parts.joined(separator: "  ")
    }.joined(separator: "\n")
  }

  var json: String {
    encoded(
      map {
        QuickAppItem(
          app: $0.app, name: $0.name, leader: $0.leader, shortcut: $0.shortcut, shown: $0.isShown,
          problem: $0.problem)
      })
  }
}

private struct QuickAppItem: Encodable {
  var app: String
  var name: String?
  var leader: String?
  var shortcut: String?
  var shown: Bool
  var problem: String?
}
