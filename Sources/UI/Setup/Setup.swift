import AppKit
import AtelierKit
import SwiftUI

/// The setup window: what Atelier needs from macOS and how it is driven, on
/// one compact page. It opens on the installed app's first launch and from
/// the menu bar. macOS sends no word when a permission or the login item
/// changes, so the page is read again whenever its window gets the keyboard,
/// which is what coming back from System Settings does.
@MainActor
public final class Setup: NSObject, NSWindowDelegate {
  private let atelier: Atelier
  private let model = SetupModel()
  private var window: NSWindow?

  public init(atelier: Atelier) {
    self.atelier = atelier
    super.init()
    Task {
      for await _ in await atelier.config.changes() { await refresh() }
    }
  }

  public func show() {
    Task {
      await refresh()
      let window = window ?? makeWindow()
      self.window = window
      // Atelier has no Dock icon, so its window comes forward only if asked.
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
    }
  }

  public func windowDidBecomeKey(_ notification: Notification) {
    Task { await refresh() }
  }

  private func makeWindow() -> NSWindow {
    let content = NSHostingController(
      rootView: SetupView(
        model: model,
        act: { [unowned self] action in
          // Coming back from System Settings reads the page again, and so does
          // a reload, through the configuration's changes.
          switch action {
          case .openAccessibilitySettings: atelier.permissions.requestAccessibility()
          case .openLoginSettings: atelier.login.openSettings()
          case .addLoginItem:
            atelier.login.register()
            Task { await refresh() }
          case .openConfiguration: Task { await atelier.attempt(.configOpen) }
          case .reloadConfiguration: Task { await atelier.attempt(.configReload) }
          }
        }))
    // The page grows and shrinks with what there is to say.
    content.sizingOptions = [.preferredContentSize]
    let window = NSWindow(contentViewController: content)
    window.styleMask = [.titled, .closable]
    window.title = "Atelier Setup"
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    return window
  }

  private func refresh() async {
    let report = await atelier.config.show()
    model.hasAccessibility = atelier.permissions.hasAccessibility
    model.login = atelier.login.status()
    model.canAddLoginItem = atelier.login.isInstalled
    model.leaderKeyPieces = report.leaderKeyPieces
    model.windowListModifierPieces = report.windowListModifierPieces
    model.spaceListModifierPieces = report.spaceListModifierPieces
    model.configurationFile = report.filePath
    model.rejection = report.rejection
    model.problems = report.problems.filter { $0 != report.rejection }
  }
}

@MainActor @Observable
final class SetupModel {
  var hasAccessibility = true
  var login: LoginStatus?
  var canAddLoginItem = false
  var leaderKeyPieces: [String]?
  var windowListModifierPieces: [String] = []
  /// Nil when the list of Spaces is turned off.
  var spaceListModifierPieces: [String]?
  var configurationFile: String?
  /// Why the file was refused whole, if it was; then none of it applies.
  var rejection: Problem?
  /// Problems with settings of the configuration in effect.
  var problems: [Problem] = []
}
