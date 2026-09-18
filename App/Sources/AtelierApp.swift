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
  private var menuBar: MenuBar?
  private var hud: HUD?

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let atelier = try Atelier.live()
      Appearance.follow(atelier)
      menuBar = MenuBar(atelier: atelier)
      hud = HUD(atelier: atelier)
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
}
