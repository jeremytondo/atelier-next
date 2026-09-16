// The JSON-lines contract between the API's pipe client and this binary. A
// request line carries `id` and `command` beside the command's own fields; the
// response line carries the same `id`, `ok`, and either `result` or `error`.
// Commands are named `<provider>.<function>` after the HS2 module the provider
// stands in for. The client refuses a `hello` whose `protocolVersion` differs
// from its own, so bump the version whenever a request or response shape changes.
import CoreGraphics
import Foundation

/// The one error type the providers report to JavaScript.
struct ProviderError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

public enum PipeProtocol {
  public static let version = 4
  /// Longer request lines are refused before parsing.
  static let maximumRequestBytes = 65536

  typealias Handler = (Data) throws -> any Encodable

  /// Adapts a typed handler to the single closure shape the dispatch table holds.
  static func handler<Request: Decodable>(
    _ body: @escaping (Request) throws -> any Encodable
  ) -> Handler {
    { data in try body(decode(Request.self, from: data)) }
  }

  /// The response line for one request line, without a trailing newline.
  static func respond(to line: String, using commands: [String: Handler]) -> String {
    let data = Data(line.utf8)
    var id: Int?
    let outcome = Result<any Encodable, Error> {
      guard data.count < maximumRequestBytes, let envelope = try? decode(Envelope.self, from: data)
      else { throw ProviderError("Invalid JSON request") }
      id = envelope.id
      guard let handler = commands[envelope.command] else {
        throw ProviderError("Unknown command: \(envelope.command)")
      }
      return try handler(data)
    }
    let response: Response
    switch outcome {
    case .success(let result): response = Response(id: id, ok: true, result: Boxed(result))
    case .failure(let error):
      response = Response(id: id, ok: false, error: error.localizedDescription)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Every type in the table is a plain struct of scalars, arrays, and
    // optionals, so encoding cannot fail; a crash here would be a programming error.
    return String(decoding: try! encoder.encode(response), as: UTF8.self)
  }

  private struct Envelope: Decodable {
    let id: Int?
    let command: String
  }

  private struct Response: Encodable {
    let id: Int?
    let ok: Bool
    var result: Boxed? = nil
    var error: String? = nil
  }

  private struct Boxed: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
  }

  private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value
  {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch let DecodingError.keyNotFound(key, _) {
      throw ProviderError("\(key.stringValue) required")
    } catch let DecodingError.typeMismatch(_, context) {
      throw ProviderError(
        "Invalid \(context.codingPath.map(\.stringValue).joined(separator: ".")) value")
    } catch let DecodingError.valueNotFound(_, context) {
      throw ProviderError(
        "Invalid \(context.codingPath.map(\.stringValue).joined(separator: ".")) value")
    }
  }
}

// MARK: - Requests

struct NoArguments: Decodable {}

/// `spaces.switch`, `spaces.create`, `spaces.reorder`, and `spaces.delete`.
/// `display` and `current` are the target the JavaScript side last observed;
/// the operation refuses if either moved.
struct SpaceRequest: Decodable {
  var display: String?
  var current: String?
  var number: Int?
  var offset: Int?
}

struct MembershipRequest: Decodable {
  let window: UInt32
}

/// `spaces.pin`: put one window's process on every listed Desktop. `app` is
/// the resolved bundle path, needed for the Dock-menu fallback route.
struct PinRequest: Decodable {
  let pid: Int32
  let window: UInt32
  let app: String
  let spaces: [String]
}

struct ApplicationRequest: Decodable {
  let app: String
}

struct LaunchRequest: Decodable {
  let path: String
}

// MARK: - Responses

struct HelloResponse: Encodable {
  let protocolVersion: Int
  let trusted: Bool
}

/// Topology, focus, and the window census the JavaScript side lists per Desktop.
/// Space mutations answer with a fresh snapshot plus their own fields.
struct Snapshot: Encodable {
  var trusted: Bool
  var focused: UInt32
  /// The Space that receives keyboard input; window commands act on its Desktop.
  var focusedSpace: String
  var targetDisplay: String
  var missionControl: Bool
  var displays: [Display]
  var windows: [Window]
  /// Whether `displays` and `windows` are complete; false leaves the JavaScript side's lists as they were.
  var complete: Bool
  /// Set by `spaces.create`: the new Desktop's ID.
  var created: String? = nil
  /// Set by `spaces.delete`: where each window of the deleted Desktop ended up.
  var migratedWindows: [WindowSpaces]? = nil

  struct Display: Encodable {
    let id: String
    let current: String
    let spaces: [Space]
  }

  struct Space: Encodable {
    let id: String
    let fullscreen: Bool
  }

  struct Window: Encodable, Equatable {
    let id: UInt32
    let pid: Int32
    /// The process launch time in seconds since 1970; with the PID, a process identity that a
    /// restart cannot recycle. 0 when unknown.
    let launched: Double
    let app: String
    let bundleID: String
    let title: String
    /// Desktop membership; empty when WindowServer reports none.
    let spaces: [String]
    let onScreen: Bool
    /// Whether Accessibility calls this an ordinary window; absent when it did not list the window.
    let ordinary: Bool?
  }

  struct WindowSpaces: Encodable {
    let id: UInt32
    let spaces: [String]
  }
}

struct NoopResponse: Encodable {
  let noop = true
}

struct MembershipResponse: Encodable {
  let spaces: [String]
  let focused: UInt32
}

struct PinResponse: Encodable {
  let assignment: String
}

struct ApplicationResponse: Encodable {
  let bundleID: String
  let name: String
  let path: String
}

struct LaunchResponse: Encodable {
  let pid: Int32
}
