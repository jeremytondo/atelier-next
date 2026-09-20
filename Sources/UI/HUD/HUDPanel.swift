import AppKit
import SwiftUI
import os

/// The window shell of the HUD: a floating panel that never takes the
/// keyboard, lets clicks through, and appears on every Space, holding
/// SwiftUI content. It sits in the bottom-right corner of the display it is
/// told to, 20 points in from the edges, and is as large as its content.
/// When full screen ends, Dock can strand an all-Spaces panel on one Desktop
/// without changing its collection behavior. Replace that window at most
/// once per presentation, retaining the content and never taking focus.
@MainActor
final class HUDPanel {
  private var panel: any HUDWindow
  private let hosting: NSHostingView<HUDView>
  private let makeWindow: @MainActor () -> any HUDWindow
  private var isPresented = false
  private var hasRecovered = false
  private let log = Logger(subsystem: "com.elevenideas.Atelier", category: "hud")

  init(
    content: HUDView,
    makeWindow: @escaping @MainActor () -> any HUDWindow = HUDPanel.makeWindow
  ) {
    self.makeWindow = makeWindow
    hosting = NSHostingView(rootView: content)
    // The panel is sized from the content's ideal size, read after each change.
    hosting.sizingOptions = [.intrinsicContentSize]
    panel = makeWindow()
    panel.contentView = hosting
  }

  private static func makeWindow() -> any HUDWindow {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .ignoresCycle, .canJoinAllApplications,
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
    show(content, in: screen.visibleFrame)
  }

  func show(_ content: HUDView, in visible: NSRect) {
    hosting.rootView = content
    hosting.invalidateIntrinsicContentSize()
    let size = hosting.intrinsicContentSize
    let margin: CGFloat = 20
    let origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
    isPresented = true
    present()
  }

  /// Called from AtelierKit's Space events, including while the leader or
  /// a notice is showing. A hidden HUD must stay hidden.
  func spacesChanged() {
    guard isPresented else { return }
    present()
  }

  private func present() {
    if !panel.isVisible { panel.orderFrontRegardless() }
    if !panel.isOnActiveSpace, !hasRecovered {
      // Set before touching AppKit: closing and ordering can deliver events.
      hasRecovered = true
      let frame = panel.frame
      log.notice("panel: replacing stranded window \(self.panel.windowNumber)")
      panel.contentView = nil
      panel.close()
      panel = makeWindow()
      panel.contentView = hosting
      panel.setFrame(frame, display: true)
      panel.orderFrontRegardless()
      if !panel.isOnActiveSpace {
        log.error(
          "panel: replacement is not on the active Space; waiting for the next presentation")
      }
    }
    let frame = panel.frame
    log.info(
      "panel: window \(self.panel.windowNumber), size \(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY)), on active Space \(self.panel.isOnActiveSpace)"
    )
  }

  func hide() {
    isPresented = false
    hasRecovered = false
    panel.orderOut(nil)
  }
}

/// The native window operations used by presentation, so recovery and its
/// retry bound can be tested without ordering real windows on the desktop.
@MainActor
protocol HUDWindow: AnyObject {
  var contentView: NSView? { get set }
  var frame: NSRect { get }
  var windowNumber: Int { get }
  var isVisible: Bool { get }
  var isOnActiveSpace: Bool { get }
  func setFrame(_ frame: NSRect, display: Bool)
  func orderFrontRegardless()
  func orderOut(_ sender: Any?)
  func close()
}

extension NSPanel: HUDWindow {}

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
