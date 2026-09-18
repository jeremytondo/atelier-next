// Atelier.app: the one running Atelier. It starts AtelierKit and puts the
// interface in the menu bar and the HUD. All behavior is in AtelierKit and
// everything visible is in UI.
import AppKit
import AtelierKit
import UI
import os

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static func main() {
    let app = NSApplication.shared
    app.delegate = shared
    app.run()
  }

  private static let shared = AppDelegate()
  private let log = Logger(subsystem: "com.elevenideas.Atelier", category: "app")
  private var atelier: Atelier?
  private var setup: Setup?
  private var menuBar: MenuBar?
  private var hud: HUD?

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let atelier = try Atelier.live()
      self.atelier = atelier
      Appearance.follow(atelier)
      let setup = Setup(atelier: atelier)
      self.setup = setup
      menuBar = MenuBar(atelier: atelier, showSetup: setup.show)
      hud = HUD(atelier: atelier)
      // A missing permission should not wait to be discovered, and the menu
      // cannot be opened to say so: at launch its item has no place yet.
      if atelier.login.isFirstLaunch || !atelier.permissions.hasAccessibility { setup.show() }
    } catch Server.StartError.alreadyRunning {
      log.notice("Another Atelier is already running; leaving it in charge.")
      NSApp.terminate(nil)
    } catch {
      log.fault("Atelier could not start: \(String(describing: error), privacy: .public)")
      let alert = NSAlert()
      alert.messageText = "Atelier could not start"
      alert.informativeText = String(describing: error)
      alert.runModal()
      NSApp.terminate(nil)
    }
  }

  /// Every road out comes through here: the menu's Quit, `atelier quit`,
  /// macOS, and an update. A command in progress is let finish first.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let atelier else { return .terminateNow }
    Task {
      await atelier.prepareToQuit()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
