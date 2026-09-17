// Delivery of one request to the running Atelier session: confirm Hammerspoon
// 2 is running through Launch Services, read the credentials the session
// wrote, and post the request. Every outcome is silent to the user; nothing
// here launches Hammerspoon 2, waits for a reload to finish, or sends twice.
import AppKit
import Foundation

public struct Runtime {
  public static let hammerspoonBundleIdentifier = "net.tenshu.Hammerspoon-2"
  /// Longer than any reload, so a wedged runtime cannot leave the companion waiting.
  public static let timeout: TimeInterval = 15

  /// Posts a body with headers to a URL and returns the reply body, or throws a `URLError`.
  public typealias Post = (URL, [String: String], Data) async throws -> Data

  /// Whether Hammerspoon 2 is running.
  public var hammerspoon: () -> Bool
  /// The session's credentials, or nil when it wrote none.
  public var credentials: () -> Credentials?
  public var post: Post

  public init(
    hammerspoon: @escaping () -> Bool, credentials: @escaping () -> Credentials?,
    post: @escaping Post
  ) {
    self.hammerspoon = hammerspoon
    self.credentials = credentials
    self.post = post
  }

  /// The real Mac: Launch Services for the running app, the state directory
  /// for the credentials, a plain session for the request.
  public static func live() -> Runtime {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    let session = URLSession(configuration: configuration)
    return Runtime(
      hammerspoon: {
        NSRunningApplication.runningApplications(withBundleIdentifier: hammerspoonBundleIdentifier)
          .contains { !$0.isTerminated }
      },
      credentials: {
        (try? Data(contentsOf: Credentials.path)).flatMap(Credentials.parse)
      },
      post: { url, headers, body in
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await session.data(for: request).0
      })
  }

  public enum Outcome: Equatable {
    /// Hammerspoon 2 is not running; nothing was attempted.
    case notRunning
    /// No session wrote credentials, or nothing answers on its port: Atelier is
    /// stopped or still starting.
    case unreachable
    /// The request reached the session; the reply, or nil when the connection
    /// ended without one, as it does when the request was a reload.
    case delivered(DispatchResponse?)
    /// The request could not be completed.
    case failed(String)
  }

  /// Sends the request once. A connection that closes after the request went
  /// out is a delivery without a reply, not a reason to send again.
  public func deliver(_ request: DispatchRequest) async -> Outcome {
    guard hammerspoon() else { return .notRunning }
    guard let credentials = credentials() else { return .unreachable }
    do {
      let body = try await post(credentials.url, credentials.headers, request.body)
      return .delivered(DispatchResponse.parse(body))
    } catch let error as URLError {
      switch error.code {
      case .cannotConnectToHost, .cannotFindHost: return .unreachable
      case .networkConnectionLost, .badServerResponse: return .delivered(nil)
      default: return .failed(error.localizedDescription)
      }
    } catch {
      return .failed(error.localizedDescription)
    }
  }
}
