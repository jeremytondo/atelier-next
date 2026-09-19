import Foundation
import MacOS

/// How keys are written in the configuration and shown on screen. A chord is
/// modifiers and one key joined by `+`, such as `ctrl+option+w`; a sequence is
/// chords separated by spaces, such as `w shift+left`. Names are not case
/// sensitive, and `cmd+option+1` and `option+command+1` are one chord.
enum KeyGrammar {
  struct Invalid: Error, Equatable {
    let message: String
  }

  private static let modifierNames: [String: Chord.Modifiers] = [
    "cmd": .command, "command": .command, "option": .option, "opt": .option, "alt": .option,
    "ctrl": .control, "control": .control, "shift": .shift, "fn": .function,
    "function": .function,
  ]

  /// Names for keys that are awkward to write, and the aliases people reach for.
  private static let keyNames: [String: String] = [
    "grave": "`", "minus": "-", "equal": "=", "left-bracket": "[",
    "leftbracket": "[", "right-bracket": "]", "rightbracket": "]", "comma": ",", "period": ".",
    "slash": "/", "semicolon": ";", "quote": "'", "backslash": "\\", "enter": "return",
    "esc": "escape", "backspace": "delete",
  ]

  /// A key is what it prints without modifiers: `+` is `shift+=`.
  private static let characters = Set("abcdefghijklmnopqrstuvwxyz0123456789`-=,./;'\\[]")

  /// Modifiers in the order macOS menus show them.
  private static let modifierOrder: [(Chord.Modifiers, symbol: String, name: String)] = [
    (.function, "fn", "fn"), (.control, "⌃", "ctrl"), (.option, "⌥", "option"),
    (.shift, "⇧", "shift"), (.command, "⌘", "cmd"),
  ]

  private static let keySymbols: [String: String] = [
    "left": "←", "right": "→", "up": "↑", "down": "↓", "space": "Space", "return": "↩",
    "tab": "⇥", "escape": "Esc", "delete": "⌫", "forwarddelete": "⌦", "home": "↖", "end": "↘",
    "pageup": "⇞", "pagedown": "⇟",
  ]

  /// `bare` allows a key with no modifier, as leader sequences do.
  static func chord(_ text: String, bare: Bool = false) throws(Invalid) -> Chord {
    let parts = text.trimmingCharacters(in: .whitespaces).lowercased()
      .split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard let last = parts.last, !last.isEmpty else {
      throw Invalid(
        message:
          "\"\(text)\" is not a key; write modifiers and a key joined by +, such as ctrl+option+w")
    }
    var modifiers: Chord.Modifiers = []
    for part in parts.dropLast() {
      guard let modifier = modifierNames[part] else {
        throw Invalid(
          message:
            "\"\(part)\" in \"\(text)\" is not a modifier; use cmd, option, ctrl, shift, or fn")
      }
      guard !modifiers.contains(modifier) else {
        throw Invalid(message: "\"\(text)\" names \(part) twice")
      }
      modifiers.insert(modifier)
    }
    let key = keyNames[last] ?? last
    guard Key.names.contains(key) || (key.count == 1 && characters.contains(key.first!)) else {
      throw Invalid(message: "\"\(last)\" in \"\(text)\" is not a key Atelier knows")
    }
    guard bare || !modifiers.isEmpty else {
      throw Invalid(message: "\"\(text)\" needs a modifier such as cmd, option, or ctrl")
    }
    return Chord(modifiers, key)
  }

  /// Fn is not accepted, since macOS sets it on arrow keys by itself.
  static func sequence(_ text: String) throws(Invalid) -> [Chord] {
    let tokens = text.split(whereSeparator: \.isWhitespace)
    guard !tokens.isEmpty else { throw Invalid(message: "a sequence needs at least one key") }
    return try tokens.map { token throws(Invalid) in
      let chord = try chord(String(token), bare: true)
      guard !chord.modifiers.contains(.function) else {
        throw Invalid(message: "fn cannot be part of a leader sequence")
      }
      return chord
    }
  }

  /// Modifiers alone, such as `cmd+option`.
  static func modifiers(_ text: String) throws(Invalid) -> Chord.Modifiers {
    var modifiers: Chord.Modifiers = []
    for part in text.trimmingCharacters(in: .whitespaces).lowercased().split(separator: "+") {
      guard let modifier = modifierNames[String(part)] else {
        throw Invalid(message: "\"\(part)\" in \"\(text)\" is not a modifier")
      }
      modifiers.insert(modifier)
    }
    guard !modifiers.isEmpty else { throw Invalid(message: "\"\(text)\" names no modifier") }
    return modifiers
  }

  /// A chord in the pieces a keyboard would show: `⇧` then `←`, one for each
  /// modifier and one for the key, with a named key such as `Space` kept whole.
  /// Whoever draws keys takes these, and never takes a description apart.
  static func pieces(_ chord: Chord) -> [String] {
    let key = keySymbols[chord.key] ?? (chord.key.count == 1 ? chord.key : chord.key.capitalized)
    return pieces(chord.modifiers) + [key]
  }

  static func pieces(_ modifiers: Chord.Modifiers) -> [String] {
    modifierOrder.filter { modifiers.contains($0.0) }.map(\.symbol)
  }

  /// `⌥⌘1`, `⇧←`, `fn⌃f`: a shortcut as macOS menus print it, except that a
  /// letter stays lowercase, so that `h` and `⇧h` are told apart by Shift alone.
  static func describe(_ chord: Chord) -> String {
    pieces(chord).joined()
  }

  static func describe(_ modifiers: Chord.Modifiers) -> String {
    pieces(modifiers).joined()
  }

  static func describe(_ sequence: [Chord]) -> String {
    sequence.map(describe).joined(separator: " ")
  }

  /// The chord as the configuration writes it: `ctrl+option+w`.
  static func text(_ chord: Chord) -> String {
    chord.modifiers.isEmpty ? chord.key : text(chord.modifiers) + "+" + chord.key
  }

  static func text(_ modifiers: Chord.Modifiers) -> String {
    modifierOrder.filter { modifiers.contains($0.0) }.map(\.name).joined(separator: "+")
  }

  static func text(_ sequence: [Chord]) -> String {
    sequence.map(text).joined(separator: " ")
  }
}
