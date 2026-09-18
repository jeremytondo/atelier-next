import AppKit
import SwiftUI

/// The window shell of the HUD: a floating panel that never takes the
/// keyboard, lets clicks through, and appears on every Space, holding
/// SwiftUI content. It sits in the bottom-right corner of the display it is
/// told to, 20 points in from the edges, and is as large as its content.
@MainActor
final class HUDPanel {
  private let panel: NSPanel
  private let hosting: NSHostingView<HUDView>

  init(content: HUDView) {
    hosting = NSHostingView(rootView: content)
    // The panel is sized from the content's ideal size, read after each change.
    hosting.sizingOptions = [.intrinsicContentSize]
    panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
    ]
    panel.ignoresMouseEvents = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.isExcludedFromWindowsMenu = true
    panel.contentView = hosting
  }

  /// Shows the content on `screen`, without taking the keyboard.
  func show(_ content: HUDView, on screen: NSScreen) {
    hosting.rootView = content
    hosting.invalidateIntrinsicContentSize()
    let size = hosting.intrinsicContentSize
    let visible = screen.visibleFrame
    let margin: CGFloat = 20
    let origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
    if !panel.isVisible { panel.orderFrontRegardless() }
  }

  func hide() {
    panel.orderOut(nil)
  }
}

extension NSScreen {
  /// The screen WindowServer calls `identifier`, its display UUID.
  static func named(_ identifier: String) -> NSScreen? {
    screens.first { screen in
      guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
        let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
      else { return false }
      return CFUUIDCreateString(nil, uuid) as String == identifier
    }
  }
}
