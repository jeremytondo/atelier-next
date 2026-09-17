// The envelope the companion sends to the runtime's `dispatch` and the reply
// it reads back, over one HTTP request to the session's `hs.httpserver`,
// authorised by the secret the session wrote for it. Both envelope and
// credentials are versioned together with `defaults/dispatch.ts`. A reply's
// `result` is ignored until an action needs data back.
import Foundation

public let dispatchVersion = 1
public let dispatchPath = "/dispatch"

/// What the running session wrote so the companion can reach it: only this
/// user can read the file, and it is gone once the session stops.
public struct Credentials: Equatable, Decodable {
  public let version: Int
  public let port: Int
  public let secret: String

  public init(port: Int, secret: String) {
    self.version = dispatchVersion
    self.port = port
    self.secret = secret
  }

  public static let path = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Atelier/companion.json")

  /// The credentials in a file's contents, or nil when it is not of this version.
  public static func parse(_ contents: Data) -> Credentials? {
    guard let credentials = try? JSONDecoder().decode(Credentials.self, from: contents),
      credentials.version == dispatchVersion, credentials.port > 0, !credentials.secret.isEmpty
    else { return nil }
    return credentials
  }

  public var url: URL { URL(string: "http://127.0.0.1:\(port)\(dispatchPath)")! }
  public var headers: [String: String] {
    ["Authorization": "Bearer " + secret, "Content-Type": "application/json"]
  }
}

public struct DispatchRequest: Equatable, Encodable {
  public let version: Int
  public let action: String
  public let parameters: [String: String]

  public init(action: String, parameters: [String: String] = [:]) {
    self.version = dispatchVersion
    self.action = action
    self.parameters = parameters
  }

  /// The request body: the envelope as JSON with sorted keys.
  public var body: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // A struct of strings always encodes.
    return (try? encoder.encode(self)) ?? Data()
  }
}

public struct DispatchResponse: Equatable, Decodable {
  public let version: Int
  public let ok: Bool
  public let error: String?

  public init(ok: Bool, error: String? = nil) {
    self.version = dispatchVersion
    self.ok = ok
    self.error = error
  }

  /// The runtime's reply in a response body, or nil when the body is not one of this version.
  public static func parse(_ body: Data) -> DispatchResponse? {
    guard let response = try? JSONDecoder().decode(DispatchResponse.self, from: body),
      response.version == dispatchVersion
    else { return nil }
    return response
  }
}
