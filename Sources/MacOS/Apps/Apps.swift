import AppKit

/// An app on disk, found from a name, a bundle identifier, or a path.
package struct AppReference: Equatable, Sendable {
  package let url: URL
  package let bundleID: String?
  package let name: String

  package init(url: URL, bundleID: String?, name: String) {
    self.url = url
    self.bundleID = bundleID
    self.name = name
  }
}

/// Finding, launching, hiding, and unhiding apps through AppKit and Launch
/// Services. Nothing here activates an app: showing a window is a raise.
enum Apps {
  /// The folders a name is looked for in, in order.
  private static let folders = [
    "/Applications", "/Applications/Utilities", "/System/Applications",
    "/System/Applications/Utilities", "/System/Library/CoreServices/Applications",
    NSHomeDirectory() + "/Applications",
  ]

  /// A path to an app, a bundle identifier Launch Services knows, or the
  /// name of an app in the usual folders or already running. Nil when none.
  static func find(_ reference: String) -> AppReference? {
    let text = reference.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    if text.hasPrefix("/") || text.hasPrefix("~") {
      let url = URL(filePath: (text as NSString).expandingTildeInPath)
      return Bundle(url: url).map { describe(url, $0) }
    }
    if text.contains("."),
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: text),
      let bundle = Bundle(url: url)
    {
      return describe(url, bundle)
    }
    let running = NSWorkspace.shared.runningApplications.first {
      $0.localizedName?.caseInsensitiveCompare(text) == .orderedSame
    }
    if let url = running?.bundleURL, let bundle = Bundle(url: url) { return describe(url, bundle) }
    let name = text.hasSuffix(".app") ? text : text + ".app"
    for folder in folders {
      let url = URL(filePath: folder).appending(path: name)
      if let bundle = Bundle(url: url) { return describe(url, bundle) }
    }
    return nil
  }

  private static func describe(_ url: URL, _ bundle: Bundle) -> AppReference {
    let name =
      (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? url.deletingPathExtension().lastPathComponent
    return AppReference(url: url, bundleID: bundle.bundleIdentifier, name: name)
  }

  /// The running instance, by bundle identifier, else by its bundle on disk.
  static func running(_ app: AppReference) -> NSRunningApplication? {
    if let bundleID = app.bundleID,
      let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    {
      return running
    }
    return NSWorkspace.shared.runningApplications.first { $0.bundleURL == app.url }
  }

  /// Launches, or reopens when running, without activating. The process
  /// number once macOS reports it; nil when it would not launch.
  static func launch(_ app: AppReference) async -> Int32? {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    do {
      let launched = try await NSWorkspace.shared.openApplication(
        at: app.url, configuration: configuration)
      return launched.processIdentifier
    } catch {
      return nil
    }
  }
}
