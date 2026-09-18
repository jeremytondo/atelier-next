import CoreGraphics

/// A key with modifiers, as macOS sees them. `key` names the key the same way
/// everywhere in Atelier: a single printable character, as the key prints
/// without modifiers on the current layout, such as "a", "1", or "[", or one
/// of the names in `Key.names`, such as "space" or "left".
package struct Chord: Hashable, Sendable {
  package struct Modifiers: OptionSet, Hashable, Sendable {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    package static let function = Modifiers(rawValue: 1)
    package static let control = Modifiers(rawValue: 2)
    package static let option = Modifiers(rawValue: 4)
    package static let shift = Modifiers(rawValue: 8)
    package static let command = Modifiers(rawValue: 16)
  }

  package var modifiers: Modifiers
  package var key: String

  package init(_ modifiers: Modifiers, _ key: String) {
    self.modifiers = modifiers
    self.key = key
  }
}

package enum Key {
  /// The keys that are not characters, by the names Atelier uses for them.
  package static let names = Set(
    [
      "space", "return", "tab", "escape", "delete", "forwarddelete", "left", "right", "up", "down",
      "home", "end", "pageup", "pagedown",
    ] + (1...20).map { "f\($0)" })
}

extension Chord.Modifiers {
  package init(_ flags: CGEventFlags) {
    self = []
    if flags.contains(.maskSecondaryFn) { insert(.function) }
    if flags.contains(.maskControl) { insert(.control) }
    if flags.contains(.maskAlternate) { insert(.option) }
    if flags.contains(.maskShift) { insert(.shift) }
    if flags.contains(.maskCommand) { insert(.command) }
  }
}
