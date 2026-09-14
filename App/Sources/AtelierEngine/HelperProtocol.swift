// The JSON-lines contract between bridge.js and the helper. A request line
// carries `id` and `command` beside the command's own fields; the response line
// carries the same `id`, `ok`, and either `result` or `error`. bridge.js refuses
// a `hello` whose `protocolVersion` differs from its own, so bump the version
// whenever a request or response shape changes.
import CoreGraphics
import Foundation

/// The one error type the helper reports to JavaScript.
struct EngineError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

public enum HelperProtocol {
  public static let version = 2
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
      else { throw EngineError("Invalid JSON request") }
      id = envelope.id
      guard let handler = commands[envelope.command] else {
        throw EngineError("Unknown command: \(envelope.command)")
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

  /// A helper that answers `hello` and `snapshot` without touching macOS. The
  /// bundle probe drives real HS2 process I/O against it in place of the engine.
  public static func runSelfTest() -> Never {
    setbuf(stdout, nil)
    let commands: [String: Handler] = [
      "hello": handler { (_: NoArguments) in
        HelloResponse(protocolVersion: version, trusted: true)
      },
      "snapshot": handler { (_: NoArguments) in
        Snapshot(
          trusted: true, focused: 0, targetDisplay: "", missionControl: false, displays: [],
          windows: [])
      },
    ]
    while let line = readLine() {
      print(respond(to: line, using: commands))
    }
    exit(0)
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
      throw EngineError("\(key.stringValue) required")
    } catch let DecodingError.typeMismatch(_, context) {
      throw EngineError(
        "Invalid \(context.codingPath.map(\.stringValue).joined(separator: ".")) value")
    } catch let DecodingError.valueNotFound(_, context) {
      throw EngineError(
        "Invalid \(context.codingPath.map(\.stringValue).joined(separator: ".")) value")
    }
  }
}

// MARK: - Requests

struct NoArguments: Decodable {}

/// `switch`, `create`, `reorder`, and `delete`. `display` and `current` are the
/// target the JS side last observed; the operation refuses if either moved.
struct SpaceRequest: Decodable {
  var display: String?
  var current: String?
  var number: Int?
  var offset: Int?
}

struct MembershipRequest: Decodable {
  let window: UInt32
}

struct ApplicationRequest: Decodable {
  let app: String
}

struct QuickToggleRequest: Decodable {
  let app: String
  var expectedBundleID: String?
  var size: QuickAppSize?
}

struct QuickAppSize: Codable, Equatable {
  let width: Double
  let height: Double
}

// MARK: - Responses

struct HelloResponse: Encodable {
  let protocolVersion: Int
  let trusted: Bool
}

struct Frame: Codable, Equatable {
  let x: Double
  let y: Double
  let w: Double
  let h: Double

  init(_ rect: CGRect) {
    x = rect.origin.x
    y = rect.origin.y
    w = rect.width
    h = rect.height
  }
}

/// Topology, focus, and the on-screen window inventory the JS side groups.
/// Space mutations answer with a fresh snapshot plus their own fields.
struct Snapshot: Encodable {
  var trusted: Bool
  var focused: UInt32
  var targetDisplay: String
  var missionControl: Bool
  var displays: [Display]
  var windows: [Window]
  /// Set by `create`: the new Desktop's ID.
  var created: String? = nil
  /// Set by `delete`: where each window of the deleted Desktop ended up.
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
    let space: String
    let frame: Frame
    let title: String
    let app: String
    let bundleID: String
  }

  struct WindowSpaces: Encodable {
    let id: UInt32
    let spaces: [String]
  }
}

struct NoopResponse: Encodable {
  let noop = true
}

struct ApplicationResponse: Encodable {
  let bundleID: String
  let name: String
}

struct MembershipResponse: Encodable {
  let spaces: [String]
  let focused: UInt32
}

struct QuickToggleResponse: Encodable, Equatable {
  enum Action: String, Encodable {
    case hidden
    case shown
  }
  let action: Action
  let bundleID: String
  var restoredFocus: Bool? = nil
  var window: UInt32? = nil
  var display: String? = nil
  var space: String? = nil
  var frame: Frame? = nil
  var assignment: String? = nil
}
