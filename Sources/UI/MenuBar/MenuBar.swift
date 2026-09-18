import AppKit
import AtelierKit
import SwiftUI

/// Atelier's menu-bar item and its popover. The popover lists the current
/// Desktop's windows in slot order, following them while it is open, and
/// shows the configuration's problems with the means to reload or open it.
@MainActor
public final class MenuBar: NSObject, NSPopoverDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private var model: WindowListModel!
  private var configModel: ConfigModel!
  private var isOpening = false

  public init(atelier: Atelier) {
    super.init()
    model = WindowListModel(atelier: atelier) { [unowned self] in showState() }
    configModel = ConfigModel(atelier: atelier) { [unowned self] in showState() }
    popover.behavior = .transient
    popover.delegate = self
    popover.contentViewController = NSHostingController(
      rootView: WindowListView(model: model, config: configModel))
    item.button?.target = self
    item.button?.action = #selector(toggle)
    showState()
    // A missing permission should not wait to be discovered.
    if !atelier.permissions.hasAccessibility { open() }
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
    let troubled = missing || !configModel.problems.isEmpty
    item.button?.image = NSImage(
      systemSymbolName: troubled ? "exclamationmark.triangle" : "macwindow.on.rectangle",
      accessibilityDescription: missing
        ? "Atelier needs Accessibility permission"
        : troubled ? "Atelier has configuration problems" : "Atelier")
  }
}
