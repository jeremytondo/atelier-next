import Foundation

/// One-time migration into user-owned JavaScript. Existing init.js always wins;
/// legacy files are parsed as data, preserved, and never executed.
public enum JavaScriptConfiguration {
  public static func bootstrap(directory: URL, legacy: URL? = nil, prototype: URL? = nil) throws {
    let file = directory.appendingPathComponent("init.js")
    guard !FileManager.default.fileExists(atPath: file.path) else { return }
    let toml = directory.appendingPathComponent("config.toml")
    var config = AppConfiguration()
    var source: String?
    if FileManager.default.fileExists(atPath: toml.path) {
      config = try ConfigurationFiles.load(toml).configuration
      source = "config.toml"
    } else if let legacy, FileManager.default.fileExists(atPath: legacy.path) {
      config = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: legacy))
      source = "settings.json"
    } else if let prototype, FileManager.default.fileExists(atPath: prototype.path) {
      config.quickApps = try QuickAppImporter.parse(String(contentsOf: prototype, encoding: .utf8))
      source = "quickapps.js"
    } else {
      config.quickApps = [QuickApp(app: "Calculator", shortcut: try Shortcut("cmd-shift-c"))]
    }
    try config.validate()
    var options: [String: Any] = [
      "spaces": config.spaces, "groups": config.groups, "overlay": config.overlay,
      "overlayModifiers": config.overlayModifiers, "bindings": config.bindings,
      "quickApps": config.quickApps.filter(\.enabled).map { app -> [String: Any] in
        var value: [String: Any] = ["app": app.app, "shortcut": app.shortcut.configText]
        if let size = app.size { value["size"] = ["width": size.width, "height": size.height] }
        return value
      },
    ]
    if let login = config.launchAtLogin { options["launchAtLogin"] = login }
    let data = try JSONSerialization.data(withJSONObject: options, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    let comment = source.map { "// Imported from \($0); the original file is preserved.\n" } ?? ""
    let script = """
      // Your Atelier configuration. Edit, then choose Reload Config.
      // Bundled defaults supply omitted options. Set a binding to "none" to disable it.
      // Use hs APIs directly or require("./my-module.js") for your own automations.
      // See Configuration Reference in the Atelier menu for examples.
      \(comment)atelier.start(\(String(decoding: data, as: UTF8.self))).catch(console.error);

      """
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data(script.utf8).write(to: file, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
