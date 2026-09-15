// Canonical configuration selection and exclusive first-run seeding. Legacy
// configuration and HS2 preferences never participate in normal bootstrap.
import Foundation

enum AtelierConfiguration {
  static func location(environment: [String: String], home: URL) throws -> URL {
    if let override = environment["ATELIER_CONFIG_DIR"] {
      guard override.hasPrefix("/") else {
        throw CocoaError(
          .fileReadInvalidFileName,
          userInfo: [NSLocalizedDescriptionKey: "ATELIER_CONFIG_DIR must be an absolute directory."]
        )
      }
      return URL(fileURLWithPath: override).appendingPathComponent("init.js")
    }
    let base =
      environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
      ?? home.appendingPathComponent(".config")
    return base.appendingPathComponent("atelier/init.js")
  }

  static func seed(at file: URL, from template: URL, files: FileManager = .default) throws {
    try files.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    // copyItem refuses to replace an existing destination, including one
    // created between this check and the copy. Empty/invalid files win too.
    if files.fileExists(atPath: file.path) { return }
    do { try files.copyItem(at: template, to: file) } catch CocoaError.fileWriteFileExists {
      return
    }
  }
}
