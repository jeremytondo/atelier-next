import ApplicationServices

/// The window arrangements macOS itself offers in an app's Window menu: Fill,
/// Center, the halves, corners, and arrangements of several windows. Named
/// as the `atelier` command names them.
package enum Arrangement: String, CaseIterable, Sendable {
  case fill, center, left, right, top, bottom
  case topLeft = "top-left"
  case topRight = "top-right"
  case bottomLeft = "bottom-left"
  case bottomRight = "bottom-right"
  case leftRight = "left-right"
  case rightLeft = "right-left"
  case topBottom = "top-bottom"
  case bottomTop = "bottom-top"
  case leftQuarters = "left-quarters"
  case rightQuarters = "right-quarters"
  case topQuarters = "top-quarters"
  case bottomQuarters = "bottom-quarters"
  case quarters

  /// Apple's label for the menu item.
  package var label: String {
    switch self {
    case .fill: "Fill"
    case .center: "Center"
    case .left: "Left"
    case .right: "Right"
    case .top: "Top"
    case .bottom: "Bottom"
    case .topLeft: "Top Left"
    case .topRight: "Top Right"
    case .bottomLeft: "Bottom Left"
    case .bottomRight: "Bottom Right"
    case .leftRight: "Left & Right"
    case .rightLeft: "Right & Left"
    case .topBottom: "Top & Bottom"
    case .bottomTop: "Bottom & Top"
    case .leftQuarters: "Left & Quarters"
    case .rightQuarters: "Right & Quarters"
    case .topQuarters: "Top & Quarters"
    case .bottomQuarters: "Bottom & Quarters"
    case .quarters: "Quarters"
    }
  }

  /// The identifier AppKit gives the menu item, from the action it performs.
  /// It does not change with the interface language.
  var identifier: String {
    switch self {
    case .fill: "_zoomFill:"
    case .center: "_zoomCenter:"
    case .left: "_zoomLeft:"
    case .right: "_zoomRight:"
    case .top: "_zoomTop:"
    case .bottom: "_zoomBottom:"
    case .topLeft: "_zoomTopLeft:"
    case .topRight: "_zoomTopRight:"
    case .bottomLeft: "_zoomBottomLeft:"
    case .bottomRight: "_zoomBottomRight:"
    case .leftRight: "_zoomLeftAndRight:"
    case .rightLeft: "_zoomRightAndLeft:"
    case .topBottom: "_zoomTopAndBottom:"
    case .bottomTop: "_zoomBottomAndTop:"
    case .leftQuarters: "_zoomLeftThreeUp:"
    case .rightQuarters: "_zoomRightThreeUp:"
    case .topQuarters: "_zoomTopThreeUp:"
    case .bottomQuarters: "_zoomBottomThreeUp:"
    case .quarters: "_zoomQuarters:"
    }
  }
}

/// One arrangement as an app's Window menu lists it.
package struct ArrangementItem: Equatable, Sendable {
  /// Whether macOS enables it for the focused window right now.
  package var isEnabled: Bool
  /// The menu item's own shortcut, when its description can be read.
  package var shortcut: Chord?

  package init(isEnabled: Bool, shortcut: Chord? = nil) {
    self.isEnabled = isEnabled
    self.shortcut = shortcut
  }
}

package enum ArrangeResult: Equatable, Sendable {
  case pressed
  /// The app's Window menu has no such item.
  case missing
  /// macOS has disabled the item for the focused window.
  case disabled
  /// Another window took the keyboard since the caller chose its target.
  case windowChanged
  /// The app did not answer in time.
  case unanswered
}

/// Reads and presses the arrangement items of an app's Window menu through
/// Accessibility. The items are found by identifier under whichever top-level
/// menu holds them, at most one submenu down, and pressed as menu items, so
/// macOS chooses the participating windows and the layout. Nothing here
/// computes a frame or posts a keystroke.
struct WindowMenu: Sendable {
  let skyLight: SkyLight

  /// Arrow keys as `AXMenuItemCmdVirtualKey` names them.
  private static let arrows: [Int: String] = [123: "left", 124: "right", 125: "down", 126: "up"]

  /// How deep the menu is walked; the items sit at most one submenu down.
  private static let depth = 3

  /// Nil when the app did not describe a menu bar.
  func read(app pid: pid_t) -> [Arrangement: ArrangementItem]? {
    guard let items = scan(app: pid) else { return nil }
    return items.mapValues { item in
      ArrangementItem(
        isEnabled: item.attribute(kAXEnabledAttribute) as? Bool == true,
        shortcut: shortcut(of: item))
    }
  }

  /// Presses the item, provided `window` still has the keyboard in `app`.
  func perform(_ arrangement: Arrangement, app pid: pid_t, window: UInt32) -> ArrangeResult {
    guard let items = scan(app: pid) else { return .unanswered }
    guard let item = items[arrangement] else { return .missing }
    guard item.attribute(kAXEnabledAttribute) as? Bool == true else { return .disabled }
    // The menu describes the focused window of the frontmost app; no other
    // may receive the action. An app that lost the keyboard still remembers
    // its focused window, so being frontmost is checked as well.
    let app = AXUIElementCreateApplication(pid)
    guard app.attribute(kAXFrontmostAttribute) as? Bool == true,
      app.element(kAXFocusedWindowAttribute).flatMap(skyLight.windowID) == window
    else { return .windowChanged }
    guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
      return .unanswered
    }
    return .pressed
  }

  private func scan(app pid: pid_t) -> [Arrangement: AXUIElement]? {
    guard let bar = AXUIElementCreateApplication(pid).element(kAXMenuBarAttribute),
      let menus = bar.attribute(kAXChildrenAttribute) as? [AXUIElement]
    else { return nil }
    // Whichever top-level menu lists the items is the Window menu; its English
    // title only says which to try first.
    let ordered =
      menus.filter { $0.attribute(kAXTitleAttribute) as? String == "Window" }
      + menus.filter { $0.attribute(kAXTitleAttribute) as? String != "Window" }
    let byIdentifier = Dictionary(
      uniqueKeysWithValues: Arrangement.allCases.map { ($0.identifier, $0) })
    for menu in ordered {
      guard let list = (menu.attribute(kAXChildrenAttribute) as? [AXUIElement])?.first else {
        continue
      }
      var items: [Arrangement: AXUIElement] = [:]
      collect(list, depth: Self.depth, byIdentifier: byIdentifier, into: &items)
      if !items.isEmpty { return items }
    }
    return [:]
  }

  private func collect(
    _ menu: AXUIElement, depth: Int, byIdentifier: [String: Arrangement],
    into items: inout [Arrangement: AXUIElement]
  ) {
    for item in menu.attribute(kAXChildrenAttribute) as? [AXUIElement] ?? [] {
      let identifier = item.attribute(kAXIdentifierAttribute) as? String
      if let identifier, let arrangement = byIdentifier[identifier] {
        if items[arrangement] == nil { items[arrangement] = item }
        continue
      }
      guard depth > 1, identifier == nil,
        let title = item.attribute(kAXTitleAttribute) as? String, !title.isEmpty,
        let submenu = (item.attribute(kAXChildrenAttribute) as? [AXUIElement])?.first
      else { continue }
      collect(submenu, depth: depth - 1, byIdentifier: byIdentifier, into: &items)
    }
  }

  /// The modifier mask is documented for Command, Shift, Option, Control, and
  /// "no Command"; bit 16 is Fn, seen on macOS's own Fn-Control shortcuts.
  /// Any other bit makes the shortcut unreadable and it is left out.
  private func shortcut(of item: AXUIElement) -> Chord? {
    guard let mask = (item.attribute("AXMenuItemCmdModifiers") as? NSNumber)?.intValue,
      (0...31).contains(mask)
    else { return nil }
    let key: String?
    if let character = item.attribute("AXMenuItemCmdChar") as? String, character.count == 1,
      let scalar = character.unicodeScalars.first, (0x21...0x7E).contains(scalar.value)
    {
      key = character.lowercased()
    } else if let virtualKey = (item.attribute("AXMenuItemCmdVirtualKey") as? NSNumber)?.intValue {
      key = Self.arrows[virtualKey]
    } else {
      key = nil
    }
    guard let key else { return nil }
    var modifiers: Chord.Modifiers = []
    if mask & 16 != 0 { modifiers.insert(.function) }
    if mask & 4 != 0 { modifiers.insert(.control) }
    if mask & 2 != 0 { modifiers.insert(.option) }
    if mask & 1 != 0 { modifiers.insert(.shift) }
    if mask & 8 == 0 { modifiers.insert(.command) }
    return Chord(modifiers, key)
  }
}
