import Foundation

/// What the `atelier` command and the running app agree on. The app does the
/// work and words the answer; the command only carries both. This interface is
/// unstable until Atelier's first release.
public struct Request: Codable, Equatable, Sendable {
  /// A grouped AtelierKit name such as `windows.list`.
  public var name: String
  /// What the name needs to be complete, such as the slot for `windows.select`.
  public var arguments: [String]
  /// Asks for JSON in place of text meant for a person.
  public var json: Bool

  public init(name: String, arguments: [String] = [], json: Bool = false) {
    self.name = name
    self.arguments = arguments
    self.json = json
  }
}

public struct Reply: Codable, Equatable, Sendable {
  public var ok: Bool
  public var output: String
  /// True when the request was refused only because another command was
  /// running, so asking again shortly may well work. Absent otherwise, and
  /// from an app too old to say.
  public var busy: Bool?

  public init(ok: Bool, output: String, busy: Bool? = nil) {
    self.ok = ok
    self.output = output
    self.busy = busy
  }
}

/// JSON as Atelier prints it for `--json`, the same from the app and the command.
package func encoded(_ payload: some Encodable) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: (try? encoder.encode(payload)) ?? Data(), as: UTF8.self)
}
