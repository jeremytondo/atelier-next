import Client
import Foundation

/// Answers requests from outside the app with the same queries the interface
/// uses, and words the answers, so every client says the same thing.
extension Session {
  package func reply(to request: Request) async -> Reply {
    do {
      guard let output = try await answer(request) else {
        return Reply(
          ok: false, output: "Atelier has no request \(request.name) that takes those arguments.")
      }
      return Reply(ok: true, output: output)
    } catch {
      return Reply(ok: false, output: error.message)
    }
  }

  /// Nil for a name or arguments Atelier does not know.
  private func answer(_ request: Request) async throws(AtelierError) -> String? {
    let arguments = request.arguments
    let number = arguments.count == 1 ? Int(arguments[0]) : nil
    let outcome: Outcome
    switch (request.name, arguments.first, arguments.count) {
    case ("windows.list", nil, _):
      let list = try await windows.list()
      return request.json ? list.json : list.text
    case ("spaces.list", nil, _):
      let list = try await spaces.list()
      return request.json ? list.json : list.text
    case ("windows.select", _, 1):
      guard let number else { return nil }
      outcome = try await windows.select(number)
    case ("windows.cycle", "next", 1): outcome = try await windows.cycle(.next)
    case ("windows.cycle", "previous", 1): outcome = try await windows.cycle(.previous)
    case ("windows.move", "by", 2):
      guard let offset = Int(arguments[1]) else { return nil }
      outcome = try await windows.move(.by(offset))
    case ("windows.move", "to", 2):
      guard let slot = Int(arguments[1]) else { return nil }
      outcome = try await windows.move(.toSlot(slot))
    case ("spaces.next", nil, _): outcome = try await spaces.next()
    case ("spaces.previous", nil, _): outcome = try await spaces.previous()
    case ("spaces.select", _, 1):
      guard let number else { return nil }
      outcome = try await spaces.select(position: number)
    case ("spaces.move", _, 2):
      guard let from = Int(arguments[0]), let to = Int(arguments[1]) else { return nil }
      outcome = try await spaces.move(from: from, to: to)
    case ("desktops.new", nil, _): outcome = try await desktops.new()
    case ("desktops.select", _, 1):
      guard let number else { return nil }
      outcome = try await desktops.select(number: number)
    case ("desktops.delete", nil, _): outcome = try await desktops.delete()
    default: return nil
    }
    return request.json
      ? #"{"outcome": "\#(outcome)"}"# : outcome == .done ? "Done." : "Nothing to do."
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

private func encoded(_ payload: some Encodable) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: (try? encoder.encode(payload)) ?? Data(), as: UTF8.self)
}

extension WindowList {
  public static let notDesktopMessage =
    "The current Space is a full-screen or Split View Space, not a Desktop."

  var text: String {
    guard case .desktop(let windows) = self else { return Self.notDesktopMessage }
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
      case .desktop(let windows):
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
