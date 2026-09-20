import AppKit
import SwiftUI
import os

/// The window shell of the HUD: a floating panel that never takes the
/// keyboard, lets clicks through, and appears on every Space, holding
/// SwiftUI content. It sits in the bottom-right corner of the display it is
/// told to, 20 points in from the edges, and is as large as its content.
///
/// A panel that is hidden when a full-screen Space closes is left on one
/// Desktop only, whatever its collection behavior says, and only a new window
/// cures that. So a panel found off the active Space is replaced as it is
/// shown, at most once until the HUD is next hidden.
@MainActor
final class HUDPanel {
  private var panel: NSPanel
  private let hosting: NSHostingView<HUDView>
  private var hasReplaced = false
  private let log = Logger(subsystem: "com.elevenideas.Atelier", category: "hud")

  init(content: HUDView) {
    hosting = NSHostingView(rootView: content)
    // The panel is sized from the content's ideal size, read after each change.
    hosting.sizingOptions = [.intrinsicContentSize]
    panel = HUDPanel.makePanel()
    panel.contentView = hosting
  }

  private static func makePanel() -> NSPanel {
    let panel = NSPanel(
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
    return panel
  }

  /// Shows the content on `screen`, without taking the keyboard.
  func show(_ content: HUDView, on screen: NSScreen) {
    hosting.rootView = content
    hosting.invalidateIntrinsicContentSize()
    let size = hosting.intrinsicContentSize
    let visible = screen.visibleFrame
    let margin: CGFloat = 20
    let origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
    let frame = NSRect(origin: origin, size: size)
    panel.setFrame(frame, display: true)
    let wasVisible = panel.isVisible
    if !panel.isVisible { panel.orderFrontRegardless() }
    if !panel.isOnActiveSpace, !hasReplaced {
      hasReplaced = true
      log.notice("panel: window \(self.panel.windowNumber) is off the active Space; replacing it")
      panel.contentView = nil
      panel.close()
      panel = HUDPanel.makePanel()
      panel.contentView = hosting
      panel.setFrame(frame, display: true)
      panel.orderFrontRegardless()
    }
    log.info(
      "panel: size \(Int(size.width))x\(Int(size.height)) at \(Int(origin.x)),\(Int(origin.y)), was visible \(wasVisible), on active Space \(self.panel.isOnActiveSpace), occluded \(!self.panel.occlusionState.contains(.visible))"
    )
  }

  func hide() {
    hasReplaced = false
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
