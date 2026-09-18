import AppKit
import AtelierKit

/// Atelier's menu-bar item and its menu: what is wrong, if anything, with the
/// means to put it right, reloading or opening the configuration, and the way
/// to the setup window. The icon says when there is something to read.
@MainActor
public final class MenuBar: NSObject, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private let atelier: Atelier
  private let showSetup: @MainActor () -> Void
  private var config: ConfigModel!

  public init(atelier: Atelier, showSetup: @escaping @MainActor () -> Void) {
    self.atelier = atelier
    self.showSetup = showSetup
    super.init()
    config = ConfigModel(atelier: atelier) { [unowned self] in render() }
    menu.delegate = self
    item.menu = menu
    render()
  }

  /// macOS does not say when the permission is granted, so each opening asks.
  public func menuNeedsUpdate(_ menu: NSMenu) {
    render()
  }

  private func render() {
    let missing = !atelier.permissions.hasAccessibility
    let troubled = missing || !config.problems.isEmpty
    item.button?.image = NSImage(
      systemSymbolName: troubled ? "exclamationmark.triangle" : "macwindow.on.rectangle",
      accessibilityDescription: missing
        ? "Atelier needs Accessibility permission"
        : troubled ? "Atelier has configuration problems" : "Atelier")
    menu.items =
      (missing ? accessibilityItems + [.separator()] : []) + configItems + [
        .separator(), setupItem, .separator(),
        NSMenuItem(
          title: "Quit Atelier", action: #selector(NSApplication.terminate), keyEquivalent: "q"),
      ]
  }

  private var accessibilityItems: [NSMenuItem] {
    let open = NSMenuItem(
      title: "Open Accessibility Settings…", action: #selector(requestAccessibility),
      keyEquivalent: "")
    open.target = self
    open.subtitle = "Atelier reads other apps' windows through Accessibility."
    return [.sectionHeader(title: "Accessibility Permission Needed"), open]
  }

  private var setupItem: NSMenuItem {
    let item = NSMenuItem(title: "Setup…", action: #selector(openSetup), keyEquivalent: "")
    item.target = self
    return item
  }

  private var configItems: [NSMenuItem] {
    // Choosing a problem opens the file it is in.
    let problems = config.problems.map { problem in
      let row = item(problem.location, .configOpen)
      row.subtitle = problem.message
      row.toolTip = problem.text
      return row
    }
    return (problems.isEmpty ? [] : [.sectionHeader(title: "Configuration Problems")] + problems)
      + [item(.configReload), item(.configOpen)]
  }

  private func item(_ command: Command) -> NSMenuItem {
    item(command.label, command)
  }

  private func item(_ title: String, _ command: Command) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
    item.target = self
    item.representedObject = command
    return item
  }

  /// The menu has closed by now, so a failure is a notice.
  @objc private func run(_ sender: NSMenuItem) {
    guard let command = sender.representedObject as? Command else { return }
    Task { await atelier.attempt(command) }
  }

  @objc private func openSetup() {
    showSetup()
  }

  @objc private func requestAccessibility() {
    atelier.permissions.requestAccessibility()
  }
}
