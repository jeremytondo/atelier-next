import Client
import Foundation

/// Answers requests from outside the app with the same queries the interface
/// uses, and words the answers, so every client says the same thing.
extension Session {
  package func reply(to request: Request) async -> Reply {
    switch request.name {
    case "windows.list":
      do {
        let list = try await windows.list()
        return Reply(ok: true, output: request.json ? list.json : list.text)
      } catch {
        return Reply(ok: false, output: error.message)
      }
    default:
      return Reply(ok: false, output: "Atelier has no request named \(request.name).")
    }
  }
}

extension WindowListError {
  public var message: String {
    switch self {
    case .accessibilityRequired:
      "Atelier needs the Accessibility permission. Open Atelier in the menu bar to grant it."
    case .unavailable: "macOS did not describe its windows. Try again."
    }
  }
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
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(payload)) ?? Data(), as: UTF8.self)
  }
}
