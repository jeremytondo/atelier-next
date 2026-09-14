import AppKit
import Foundation

/// A configured Quick App resolved to the bundle on disk it names.
struct TargetApplication: Equatable {
  let url: URL
  let bundleIdentifier: String
  let name: String

  /// Accepts an absolute or tilde path, a bundle identifier, or an application
  /// name with or without `.app`, searched across the standard Applications folders.
  @MainActor
  static func resolve(_ value: String) throws -> TargetApplication {
    let url: URL?
    if value.contains("/") {
      url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
    } else if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) {
      url = bundleURL
    } else {
      url = applicationURL(named: value)
    }
    guard let url, FileManager.default.fileExists(atPath: url.path),
      let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier
    else {
      throw EngineError("Could not find application: \(value)")
    }
    let name =
      (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? url.deletingPathExtension().lastPathComponent
    return TargetApplication(url: url, bundleIdentifier: bundleIdentifier, name: name)
  }

  private static func applicationURL(named value: String) -> URL? {
    let requestedName = value.hasSuffix(".app") ? value : "\(value).app"
    let roots = FileManager.default.urls(
      for: .applicationDirectory, in: [.userDomainMask, .localDomainMask, .systemDomainMask])
    for root in roots {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: [.isApplicationKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }
      for case let candidate as URL in enumerator
      where candidate.lastPathComponent.caseInsensitiveCompare(requestedName) == .orderedSame {
        return candidate
      }
    }
    return nil
  }
}
