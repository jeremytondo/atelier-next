import Foundation

/// What only the running app can say about itself, for `atelier doctor`. The
/// command adds what it can see from outside, and words the whole.
public struct AppReport: Codable, Equatable, Sendable {
  public struct Problem: Codable, Equatable, Sendable {
    public var location: String
    public var message: String

    public init(location: String, message: String) {
      self.location = location
      self.message = message
    }
  }

  public struct Login: Codable, Equatable, Sendable {
    /// One of enabled, requiresApproval, notRegistered, notFound.
    public var status: String
    /// True when something stands in the way; an item the user removed does not.
    public var needsAttention: Bool
    public var summary: String
    public var advice: String?

    public init(status: String, needsAttention: Bool, summary: String, advice: String?) {
      self.status = status
      self.needsAttention = needsAttention
      self.summary = summary
      self.advice = advice
    }
  }

  public var version: String
  public var build: String
  /// Where the running app is on disk.
  public var path: String
  public var hasAccessibility: Bool
  public var login: Login
  public var configurationFile: String?
  public var configurationProblems: [Problem]

  public init(
    version: String, build: String, path: String, hasAccessibility: Bool, login: Login,
    configurationFile: String?, configurationProblems: [Problem]
  ) {
    self.version = version
    self.build = build
    self.path = path
    self.hasAccessibility = hasAccessibility
    self.login = login
    self.configurationFile = configurationFile
    self.configurationProblems = configurationProblems
  }
}
