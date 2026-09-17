// Atelier.app: the companion that owns Atelier's app identity so macOS can
// offer its actions in Spotlight. It has no window, no state, and no
// behavior of its own; each action is delivered to the running session and
// forgotten. Info.plist lets macOS end the process whenever it is idle.
import AppKit
import Companion
import os

let log = Logger(subsystem: "com.elevenideas.Atelier", category: "companion")
let runtime = Runtime.live()

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
  static func main() {
    let app = NSApplication.shared
    app.delegate = AppDelegate.shared
    app.run()
  }

  static let shared = AppDelegate()

  func applicationDidFinishLaunching(_ notification: Notification) {
    AtelierShortcuts.updateAppShortcutParameters()
  }
}
