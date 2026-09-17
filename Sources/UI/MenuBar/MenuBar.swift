import AppKit
import AtelierKit
import SwiftUI

/// Atelier's menu-bar item and its popover. For now the popover lists the
/// current Desktop's windows in slot order, and follows them while it is open.
@MainActor
public final class MenuBar: NSObject, NSPopoverDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private var model: WindowListModel!
  private var isOpening = false

  public init(session: Session) {
    super.init()
    model = WindowListModel(session: session) { [unowned self] in showState() }
    popover.behavior = .transient
    popover.delegate = self
    popover.contentViewController = NSHostingController(rootView: WindowListView(model: model))
    item.button?.target = self
    item.button?.action = #selector(toggle)
    showState()
    // A missing permission should not wait to be discovered.
    if !session.permissions.hasAccessibility { open() }
  }

  @objc private func toggle() {
    if popover.isShown { popover.close() } else { open() }
  }

  private func open() {
    // A second click while the first is still opening would note Atelier's
    // own focus.
    guard !isOpening else { return }
    isOpening = true
    Task {
      // Showing the popover moves the keyboard to Atelier, so first note
      // where it was. The frontmost app has a moment to answer.
      await model.captureContext()
      isOpening = false
      guard let button = item.button, !popover.isShown else { return }
      NSApp.activate()
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      model.follow()
      await model.refresh()
    }
  }

  /// Hands the keyboard back to the app that had it.
  public func popoverDidClose(_ notification: Notification) {
    model.stopFollowing()
    NSApp.hide(nil)
  }

  private func showState() {
    let missing = model.state == .needsAccessibility
    item.button?.image = NSImage(
      systemSymbolName: missing ? "exclamationmark.triangle" : "macwindow.on.rectangle",
      accessibilityDescription: missing ? "Atelier needs Accessibility permission" : "Atelier")
  }
}
