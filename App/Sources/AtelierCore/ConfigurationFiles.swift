import CryptoKit
import Foundation
import TOML

/// User-owned TOML is read only at launch and on explicit reload. Runtime state
/// and the legacy JSON snapshot never participate in include/override resolution.
public enum ConfigurationFiles {
  public static func directory(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    let base: URL
    if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
      base = URL(fileURLWithPath: xdg, isDirectory: true)
    } else {
      base = home.appendingPathComponent(".config", isDirectory: true)
    }
    return base.appendingPathComponent("atelier", isDirectory: true)
  }

  public struct Loaded {
    public var configuration: AppConfiguration
    public var files: [URL]
  }

  public static func load(_ url: URL) throws -> Loaded {
    var stack: Set<URL> = []
    var files: [URL] = []
    var bytes = 0
    var result = AppConfiguration()
    var quickApps: [String: QuickApp] = [:]
    var origins: [String: URL] = [:]
    func visit(_ input: URL, depth: Int) throws {
      let file = input.standardizedFileURL.resolvingSymlinksInPath()
      guard depth <= 8, files.count < 32 else {
        throw AppError("\(input.path): include limit exceeded (8 levels, 32 files).")
      }
      guard stack.insert(file).inserted else {
        throw AppError("\(input.path): include cycle detected.")
      }
      defer { stack.remove(file) }
      files.append(input.standardizedFileURL)
      let document: Document
      do {
        let data = try Data(contentsOf: file)
        bytes += data.count
        guard data.count <= 262_144, bytes <= 1_048_576 else {
          throw AppError("Configuration is too large.")
        }
        document = try TOMLDecoder().decode(Document.self, from: data)
      } catch {
        throw AppError("\(input.path): \(describe(error))")
      }
      for include in document.include ?? [] {
        guard !include.isEmpty else {
          throw AppError("\(input.path): include paths cannot be empty.")
        }
        let expanded = (include as NSString).expandingTildeInPath
        let next =
          expanded.hasPrefix("/")
          ? URL(fileURLWithPath: expanded)
          : input.deletingLastPathComponent().appendingPathComponent(expanded)
        try visit(next, depth: depth + 1)
      }
      // Included files provide a base; this file wins. Later includes win over
      // earlier ones. A named Quick App is replaced as a complete entry.
      if let version = document.version {
        guard version == 1 else { throw AppError("\(input.path): version must be 1.") }
      }
      if let value = document.spaces { result.spaces = value }
      if let value = document.groups { result.groups = value }
      if let value = document.overlay { result.overlay = value }
      if let value = document.launchAtLogin { result.launchAtLogin = value }
      if let value = document.overlayModifiers {
        do { _ = try Shortcut(value + "-a") } catch {
          throw AppError("\(input.path): overlay-modifiers: \(error.localizedDescription)")
        }
        result.overlayModifiers = value
      }
      for (name, value) in document.bindings ?? [:] {
        guard AppConfiguration.defaultBindings[name] != nil else {
          throw AppError("\(input.path): bindings.\(name): unknown action.")
        }
        if value != "none" {
          do { _ = try Shortcut(value) } catch {
            throw AppError("\(input.path): bindings.\(name): \(error.localizedDescription)")
          }
        }
        result.bindings[name] = value
        origins["bindings.\(name)"] = input
      }
      for (name, definition) in document.quickapps ?? [:] {
        guard !name.isEmpty else { throw AppError("\(input.path): Quick Apps need a name.") }
        do {
          var app = QuickApp(
            id: identifier(name), app: definition.app,
            shortcut: try Shortcut(definition.shortcut), enabled: definition.enabled ?? true)
          app.configName = name
          if let size = definition.size {
            guard size.count == 2 else { throw AppError("size must contain [width, height].") }
            app.size = .init(width: size[0], height: size[1])
          }
          guard !app.app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            app.size?.isValid != false
          else {
            throw AppError("Provide an application and a finite, positive size.")
          }
          quickApps[name] = app
          origins["quickapps.\(name)"] = input
        } catch {
          throw AppError("\(input.path): quickapps.\(name): \(error.localizedDescription)")
        }
      }
    }
    try visit(url, depth: 0)
    result.quickApps = quickApps.keys.sorted().compactMap { quickApps[$0] }
    do { try result.validate() } catch {
      let message = error.localizedDescription
      let key = origins.keys.sorted { $0.count > $1.count }.first { message.hasPrefix($0 + ":") }
      throw AppError("\((key.flatMap { origins[$0] } ?? url).path): \(message)")
    }
    return Loaded(configuration: result, files: files)
  }

  private static func identifier(_ name: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data(("atelier.quickapp." + name).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  /// Used once, for bootstrap/migration. Never called on reload or on shutdown.
  public static func starter(_ config: AppConfiguration = AppConfiguration()) -> String {
    func quote(_ value: String) -> String {
      // JSON strings use escapes accepted by TOML basic strings. Do not escape
      // slashes; TOML does not recognize JSON's optional escaped slash.
      let data = try! JSONEncoder().encode(value)
      return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }
    var text = """
      # Atelier configuration. Saving does not change the running app.
      # Apply edits with the menu's Reload Configuration command or ⌃⌥⌘R.
      # Open Configuration Reference in the menu for all actions and examples.
      # Optional split: include = ["keybindings.toml", "quickapps.toml"]
      # Put include at the top, before any [table]. Included files load first.
      version = 1
      spaces = \(config.spaces)
      groups = \(config.groups)
      overlay = \(config.overlay)
      overlay-modifiers = \(quote(config.overlayModifiers))

      """
    if let login = config.launchAtLogin {
      text += "launch-at-login = \(login)\n"
    } else {
      text += "# launch-at-login = true\n"
    }
    text +=
      "\n[bindings]\n# Omitted actions keep their defaults; use \"none\" to disable a binding.\n"
    var bindings = config.bindings
    if bindings["reload-config"] == nil {
      bindings["reload-config"] = AppConfiguration.defaultBindings["reload-config"]
    }
    for name in bindings.keys.sorted() { text += "\(name) = \(quote(bindings[name]!))\n" }
    var usedNames: Set<String> = []
    for (index, app) in config.quickApps.enumerated() {
      let appName =
        app.app.contains("/")
        ? URL(fileURLWithPath: app.app).deletingPathExtension().lastPathComponent
        : (app.app.split(separator: ".").last.map(String.init) ?? app.app)
      let base = appName.lowercased().replacingOccurrences(
        of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
      var name = app.configName ?? (base.isEmpty ? "app-\(index + 1)" : base)
      while usedNames.contains(name) { name += "-\(index + 1)" }
      usedNames.insert(name)
      let key =
        name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) == nil ? quote(name) : name
      text +=
        "\n[quickapps.\(key)]\napp = \(quote(app.app))\nshortcut = \(quote(app.shortcut.configText))\n"
      if !app.enabled { text += "enabled = false\n" }
      if let size = app.size { text += "size = [\(size.width), \(size.height)]\n" }
    }
    if config.quickApps.isEmpty {
      text += "\n# [quickapps.calculator]\n# app = \"Calculator\"\n# shortcut = \"cmd-shift-c\"\n"
    }
    return text
  }

  private static func describe(_ error: Error) -> String {
    if let error = error as? TOMLDecodingError { return error.description }
    let context: DecodingError.Context
    let problem: String
    switch error {
    case DecodingError.keyNotFound(let key, let value):
      context = value
      problem = "missing \(key.stringValue)"
    case DecodingError.typeMismatch(_, let value), DecodingError.valueNotFound(_, let value),
      DecodingError.dataCorrupted(let value):
      context = value
      problem = value.debugDescription
    default: return error.localizedDescription
    }
    return
      ([context.codingPath.map(\.stringValue).joined(separator: "."), problem].filter {
        !$0.isEmpty
      }).joined(separator: ": ")
  }
}

private struct AnyKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

private func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
  let container = try decoder.container(keyedBy: AnyKey.self)
  for key in container.allKeys where !allowed.contains(key.stringValue) {
    throw DecodingError.dataCorrupted(
      .init(codingPath: decoder.codingPath + [key], debugDescription: "Unknown configuration key."))
  }
}

private struct Document: Decodable {
  var version: Int?
  var include: [String]?
  var spaces: Bool?
  var groups: Bool?
  var overlay: Bool?
  var overlayModifiers: String?
  var launchAtLogin: Bool?
  var bindings: [String: String]?
  var quickapps: [String: QuickDefinition]?
  enum CodingKeys: String, CodingKey, CaseIterable {
    case version, include, spaces, groups, overlay, bindings, quickapps
    case overlayModifiers = "overlay-modifiers"
    case launchAtLogin = "launch-at-login"
  }
  init(from decoder: Decoder) throws {
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decodeIfPresent(Int.self, forKey: .version)
    include = try c.decodeIfPresent([String].self, forKey: .include)
    spaces = try c.decodeIfPresent(Bool.self, forKey: .spaces)
    groups = try c.decodeIfPresent(Bool.self, forKey: .groups)
    overlay = try c.decodeIfPresent(Bool.self, forKey: .overlay)
    overlayModifiers = try c.decodeIfPresent(String.self, forKey: .overlayModifiers)
    launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
    bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings)
    quickapps = try c.decodeIfPresent([String: QuickDefinition].self, forKey: .quickapps)
  }
}

private struct QuickDefinition: Decodable {
  var app: String
  var shortcut: String
  var size: [Double]?
  var enabled: Bool?
  enum CodingKeys: String, CodingKey, CaseIterable { case app, shortcut, size, enabled }
  init(from decoder: Decoder) throws {
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    app = try c.decode(String.self, forKey: .app)
    shortcut = try c.decode(String.self, forKey: .shortcut)
    size = try c.decodeIfPresent([Double].self, forKey: .size)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
  }
}
