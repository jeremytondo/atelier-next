import MacOS
import Testing

@testable import AtelierKit

@Suite struct KeyGrammarTests {
  @Test(arguments: [
    ("ctrl+option+w", Chord([.control, .option], "w")),
    ("Command+Alt+1", Chord([.command, .option], "1")),
    ("option+space", Chord([.option], "space")),
    ("cmd+shift+left-bracket", Chord([.command, .shift], "[")),
    ("cmd+option+]", Chord([.command, .option], "]")),
    ("option+grave", Chord([.option], "`")),
    ("ctrl+backspace", Chord([.control], "delete")),
    ("fn+ctrl+f", Chord([.function, .control], "f")),
    (" cmd+F5 ", Chord([.command], "f5")),
  ])
  func parsesChords(text: String, expected: Chord) throws {
    #expect(try KeyGrammar.chord(text) == expected)
  }

  @Test(arguments: [
    "w", "cmd+w+", "cmd++", "cmd+", "+w", "super+w", "cmd+cmd+w", "cmd+ä", "cmd+f21",
    "cmd+plus",
  ])
  func refusesWhatIsNotAChord(text: String) {
    #expect(throws: KeyGrammar.Invalid.self) { try KeyGrammar.chord(text) }
  }

  @Test func sequencesTakeBareKeysButNotFn() throws {
    #expect(
      try KeyGrammar.sequence("w shift+left") == [
        Chord([], "w"), Chord([.shift], "left"),
      ])
    #expect(throws: KeyGrammar.Invalid.self) { try KeyGrammar.sequence("w fn+f") }
    #expect(throws: KeyGrammar.Invalid.self) { try KeyGrammar.sequence("  ") }
  }

  @Test func describesAsMenusDo() throws {
    #expect(KeyGrammar.describe(try KeyGrammar.chord("cmd+option+1")) == "⌥⌘1")
    #expect(KeyGrammar.describe(try KeyGrammar.chord("shift+ctrl+left", bare: true)) == "⌃⇧←")
    #expect(KeyGrammar.describe(try KeyGrammar.chord("fn+ctrl+f")) == "fn⌃f")
    #expect(KeyGrammar.describe(try KeyGrammar.chord("option+space")) == "⌥Space")
    #expect(KeyGrammar.describe(try KeyGrammar.chord("cmd+f5")) == "⌘F5")
    #expect(KeyGrammar.describe(try KeyGrammar.sequence("w a shift+left")) == "w a ⇧←")
    // A letter stays lowercase, so Shift shows only as its own symbol.
    #expect(KeyGrammar.describe(try KeyGrammar.chord("H", bare: true)) == "h")
    #expect(KeyGrammar.describe(try KeyGrammar.chord("shift+h", bare: true)) == "⇧h")
    #expect(KeyGrammar.describe(try KeyGrammar.chord("cmd+delete")) == "⌘⌫")
  }

  /// One piece for each modifier, in the order menus show them, and one for
  /// the key, which stays whole when it has a name.
  @Test(arguments: [
    ("h", ["h"]),
    ("shift+left", ["⇧", "←"]),
    ("space", ["Space"]),
    ("esc", ["Esc"]),
    ("cmd+f10", ["⌘", "F10"]),
    ("fn+ctrl+f", ["fn", "⌃", "f"]),
    ("cmd+shift+option+ctrl+fn+space", ["fn", "⌃", "⌥", "⇧", "⌘", "Space"]),
  ])
  func takesAChordApartForKeycaps(text: String, expected: [String]) throws {
    let chord = try KeyGrammar.chord(text, bare: true)
    #expect(KeyGrammar.pieces(chord) == expected)
    #expect(KeyGrammar.describe(chord) == expected.joined())
  }

  @Test func takesModifiersApartForKeycaps() throws {
    let modifiers = try KeyGrammar.modifiers("cmd+option")
    #expect(KeyGrammar.pieces(modifiers) == ["⌥", "⌘"])
    #expect(KeyGrammar.describe(modifiers) == "⌥⌘")
  }

  @Test func writesChordsBackInOneForm() throws {
    #expect(KeyGrammar.text(try KeyGrammar.chord("alt+command+1")) == "option+cmd+1")
    #expect(KeyGrammar.text(try KeyGrammar.sequence("W Shift+Left")) == "w shift+left")
    #expect(try KeyGrammar.modifiers("cmd+option") == [.command, .option])
    #expect(throws: KeyGrammar.Invalid.self) { try KeyGrammar.modifiers("cmd+w") }
  }
}
