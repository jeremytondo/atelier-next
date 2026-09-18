import Carbon.HIToolbox
import CoreGraphics

/// The key codes behind key names on the current keyboard layout. The named
/// keys sit at the same codes on every Apple keyboard; characters come from
/// the layout, so "a" is wherever the layout puts it. The digit row is a
/// fallback for layouts that put the digits behind Shift.
struct KeyCodes: Sendable {
  static let named: [String: CGKeyCode] = [
    "space": 49, "return": 36, "tab": 48, "escape": 53, "delete": 51, "forwarddelete": 117,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116,
    "pagedown": 121, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
    "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
    "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
  ]

  private static let digitRow: [String: CGKeyCode] = [
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
  ]

  private let byName: [String: CGKeyCode]
  private let byCode: [CGKeyCode: String]

  /// Reads the current layout. Text Input Services is asked on the main thread.
  @MainActor init() {
    var byName = Self.named
    // A code is named by its named key, else by the character the layout
    // puts on it, else as a digit-row fallback; in that order on both maps.
    var byCode = Dictionary(uniqueKeysWithValues: Self.named.map { ($1, $0) })
    if let layout = Self.currentLayout() {
      for code in CGKeyCode(0)..<128 where byCode[code] == nil {
        guard let character = Self.character(of: code, in: layout), byName[character] == nil
        else { continue }
        byName[character] = code
        byCode[code] = character
      }
    }
    for (digit, code) in Self.digitRow.sorted(by: { $0.value < $1.value })
    where byName[digit] == nil {
      byName[digit] = code
      if byCode[code] == nil { byCode[code] = digit }
    }
    self.byName = byName
    self.byCode = byCode
  }

  func code(for name: String) -> CGKeyCode? {
    byName[name]
  }

  func name(of code: CGKeyCode) -> String? {
    byCode[code]
  }

  private static func currentLayout() -> Data? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
      let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    return Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
  }

  /// The single printable character the key produces without modifiers, if any.
  private static func character(of code: CGKeyCode, in layout: Data) -> String? {
    layout.withUnsafeBytes { bytes -> String? in
      guard let base = bytes.baseAddress else { return nil }
      var deadKeys: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 4)
      let status = UCKeyTranslate(
        base.assumingMemoryBound(to: UCKeyboardLayout.self), code, UInt16(kUCKeyActionDisplay), 0,
        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys,
        characters.count, &length, &characters)
      guard status == noErr, length == 1, let scalar = Unicode.Scalar(characters[0]),
        scalar.isASCII, scalar.properties.isGraphemeBase, scalar != " "
      else { return nil }
      return String(Character(scalar)).lowercased()
    }
  }
}
