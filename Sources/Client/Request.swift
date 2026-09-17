import Foundation

/// What the `atelier` command and the running app agree on. The app does the
/// work and words the answer; the command only carries both. This interface is
/// unstable until Atelier's first release.
public struct Request: Codable, Equatable, Sendable {
  /// A grouped AtelierKit name such as `windows.list`.
  public var name: String
  /// Asks for JSON in place of text meant for a person.
  public var json: Bool

  public init(name: String, json: Bool = false) {
    self.name = name
    self.json = json
  }
}

public struct Reply: Codable, Equatable, Sendable {
  public var ok: Bool
  public var output: String

  public init(ok: Bool, output: String) {
    self.ok = ok
    self.output = output
  }
}
