// The actions Spotlight and Shortcuts offer. Each one is a thin caller of a
// runtime action by name; the runtime decides whether and how it runs, and no
// result, dialog, or error reaches the user from here.
import AppIntents
import Companion
import Foundation

struct ReloadConfigIntent: AppIntent {
  static let title: LocalizedStringResource = "Reload Config"
  static let description = IntentDescription(
    "Reloads your Atelier configuration in Hammerspoon 2.",
    categoryName: "Configuration",
    searchKeywords: ["reload", "config", "configuration", "hammerspoon", "atelier"])
  static let openAppWhenRun = false

  func perform() async throws -> some IntentResult {
    await deliver(DispatchRequest(action: "reload-config"))
    return .result()
  }
}

/// Delivers one request and logs the outcome for diagnosis.
func deliver(_ request: DispatchRequest) async {
  switch await runtime.deliver(request) {
  case .notRunning:
    log.info("\(request.action, privacy: .public): Hammerspoon 2 is not running")
  case .unreachable:
    log.info(
      "\(request.action, privacy: .public): Atelier is not serving; stopped or still starting")
  case .delivered(let response):
    log.info(
      "\(request.action, privacy: .public): delivered, reply \(String(describing: response), privacy: .public)"
    )
  case .failed(let reason):
    log.error("\(request.action, privacy: .public): \(reason, privacy: .public)")
  }
}

struct AtelierShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ReloadConfigIntent(),
      phrases: ["Reload \(.applicationName) config", "Reload config in \(.applicationName)"],
      shortTitle: "Reload Config",
      systemImageName: "arrow.clockwise")
  }
}
