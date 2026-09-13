import Carbon.HIToolbox
import Foundation

public struct Shortcut: Codable, Equatable, Hashable, Sendable {
  public var keyCode: UInt32
  public var modifiers: UInt32
  public init(keyCode: UInt32, modifiers: UInt32) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }
  public static let keys: [String: UInt32] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39,
    "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51,
    "escape": 53,
    "f17": 64, "f18": 79, "f19": 80, "f20": 90, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100,
    "f9": 101,
    "f11": 103, "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113, "home": 115,
    "pageup": 116,
    "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122, "left": 123,
    "right": 124, "down": 125, "up": 126,
  ]
  public init(_ text: String) throws {
    var parts = text.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(
      String.init)
    let aliases: [String: UInt32] = [
      "cmd": UInt32(cmdKey), "command": UInt32(cmdKey), "ctrl": UInt32(controlKey),
      "control": UInt32(controlKey), "alt": UInt32(optionKey), "opt": UInt32(optionKey),
      "option": UInt32(optionKey), "shift": UInt32(shiftKey),
    ]
    var flags: UInt32 = 0
    while parts.count > 1, let flag = aliases[parts[0]] {
      guard flags & flag == 0 else { throw AppError("Repeated modifier in shortcut: \(text)") }
      flags |= flag
      parts.removeFirst()
    }
    let keyAliases = [
      "grave": "`", "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/",
      "semicolon": ";", "quote": "'", "backslash": "\\", "left-bracket": "[", "right-bracket": "]",
      "enter": "return", "esc": "escape",
    ]
    let name = parts.joined(separator: "-")
    guard flags != 0, let code = Self.keys[keyAliases[name] ?? name] else {
      throw AppError("Invalid shortcut: \(text)")
    }
    self.init(keyCode: code, modifiers: flags)
  }
  public var label: String {
    var result = ""
    for (flag, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
    where modifiers & UInt32(flag) != 0 { result += symbol }
    let name = Self.keys.first(where: { $0.value == keyCode })?.key ?? "Key \(keyCode)"
    let symbols = [
      "left": "←", "right": "→", "up": "↑", "down": "↓", "delete": "⌫", "return": "↩",
      "space": "Space", "escape": "Esc", "tab": "⇥",
    ]
    return result + (symbols[name] ?? name.uppercased())
  }
  public var isValid: Bool {
    Self.keys.values.contains(keyCode) && modifiers != 0
      && modifiers & ~UInt32(cmdKey | optionKey | shiftKey | controlKey) == 0
  }
  public var configText: String {
    let modifiers = [
      (controlKey, "ctrl"), (optionKey, "option"), (shiftKey, "shift"), (cmdKey, "cmd"),
    ]
    .filter { self.modifiers & UInt32($0.0) != 0 }.map(\.1)
    let key = Self.keys.first(where: { $0.value == keyCode })?.key ?? "unknown"
    let names = [
      "-": "minus", "`": "grave", "[": "left-bracket", "]": "right-bracket",
      ",": "comma", "\\": "backslash", "'": "quote",
    ]
    return (modifiers + [names[key] ?? key]).joined(separator: "-")
  }
}

public struct QuickApp: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var app: String
  public var shortcut: Shortcut
  public var size: Size?
  public var enabled: Bool
  public var configName: String?
  public struct Size: Codable, Equatable, Sendable {
    public var width: Double, height: Double
    public init(width: Double, height: Double) {
      self.width = width
      self.height = height
    }
    public var isValid: Bool { width.isFinite && height.isFinite && width > 0 && height > 0 }
  }
  public init(
    id: UUID = UUID(), app: String, shortcut: Shortcut, size: Size? = nil, enabled: Bool = true
  ) {
    self.id = id
    self.app = app
    self.shortcut = shortcut
    self.size = size
    self.enabled = enabled
  }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var spaces = true
  public var groups = true
  public var overlay = true
  public var quickApps: [QuickApp] = []
  public var bindings: [String: String] = [:]
  public var launchAtLogin: Bool?
  public var overlayModifiers = "cmd-option"
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, spaces, groups, overlay, quickApps, bindings, launchAtLogin,
      overlayModifiers
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    spaces = try c.decodeIfPresent(Bool.self, forKey: .spaces) ?? true
    groups = try c.decodeIfPresent(Bool.self, forKey: .groups) ?? true
    overlay = try c.decodeIfPresent(Bool.self, forKey: .overlay) ?? true
    quickApps = try c.decodeIfPresent([QuickApp].self, forKey: .quickApps) ?? []
    bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings) ?? [:]
    launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
    overlayModifiers = try c.decodeIfPresent(String.self, forKey: .overlayModifiers) ?? "cmd-option"
  }
  public func validate() throws {
    guard schemaVersion == 1 else {
      throw AppError("Unsupported configuration version: \(schemaVersion). Expected 1.")
    }
    guard quickApps.count <= 50 else { throw AppError("Configure at most 50 Quick Apps.") }
    guard Set(quickApps.map(\.id)).count == quickApps.count else {
      throw AppError("Quick App identifiers must be unique.")
    }
    for app in quickApps {
      guard !app.app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, app.shortcut.isValid,
        app.size?.isValid != false
      else { throw AppError("Check the app, shortcut, and size for each Quick App.") }
    }
    _ = try Shortcut(overlayModifiers + "-a")
    _ = try effectiveBindings()
  }

  public static var defaultBindings: [String: String] {
    var result = [
      "reload-config": "ctrl-option-cmd-r", "group": "cmd-option-g",
      "cycle-previous": "cmd-option-left-bracket", "cycle-next": "cmd-option-right-bracket",
      "desktop-create": "option-grave", "desktop-left": "ctrl-option-left",
      "desktop-right": "ctrl-option-right", "desktop-delete": "ctrl-option-delete",
    ]
    for n in 1...10 {
      result["desktop-\(n)"] = "option-\(n % 10)"
      result["select-\(n)"] = "cmd-option-\(n % 10)"
    }
    return result
  }

  public func effectiveBindings() throws -> [String: Shortcut] {
    var values = Self.defaultBindings
    for (name, value) in bindings {
      guard values[name] != nil else { throw AppError("bindings.\(name): unknown action.") }
      values[name] = value
    }
    var result: [String: Shortcut] = [:]
    var used: [Shortcut: String] = [:]
    for name in values.keys.sorted() {
      let text = values[name]!
      if text == "none" { continue }
      let shortcut: Shortcut
      do { shortcut = try Shortcut(text) } catch {
        throw AppError("bindings.\(name): \(error.localizedDescription)")
      }
      if name.hasPrefix("desktop-") && !spaces { continue }
      if (name == "group" || name.hasPrefix("select-") || name.hasPrefix("cycle-")) && !groups {
        continue
      }
      if let prior = used[shortcut] {
        throw AppError("bindings.\(name): \(shortcut.label) is also used by \(prior).")
      }
      used[shortcut] = name
      result[name] = shortcut
    }
    for app in quickApps where app.enabled {
      let name = "quickapps.\(app.configName ?? app.app)"
      if let prior = used[app.shortcut] {
        throw AppError("\(name): \(app.shortcut.label) is also used by \(prior).")
      }
      used[app.shortcut] = name
    }
    return result
  }
}

public enum QuickAppImporter {
  private struct Entry: Decodable {
    var app: String
    var shortcut: String
    var size: QuickApp.Size?
  }
  /// Parses literal JSON5 data only. Functions, require(), and computed JS fail
  /// decoding and are never evaluated. Comments and the stock loader are accepted.
  public static func parse(_ source: String) throws -> [QuickApp] {
    guard source.utf8.count < 65_536 else {
      throw AppError("The prototype configuration is too large to import.")
    }
    guard let range = source.range(of: "module.exports"),
      source[..<range.lowerBound].replacingOccurrences(
        of: #"(?m)//[^\n]*"#, with: "", options: .regularExpression
      ).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AppError(
        "Import supports a literal module.exports array. Translate computed Quick Apps into Atelier configuration."
      )
    }
    var value = String(source[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("=") else { throw AppError("Expected module.exports = [ … ].") }
    value.removeFirst()
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasSuffix(";") { value.removeLast() }
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = true
    let entries = try decoder.decode([Entry].self, from: Data(value.utf8))
    let apps = try entries.map {
      QuickApp(app: $0.app, shortcut: try Shortcut($0.shortcut), size: $0.size)
    }
    var config = AppConfiguration()
    config.quickApps = apps
    try config.validate()
    return apps
  }
}
