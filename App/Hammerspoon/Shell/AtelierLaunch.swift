// One startup decision flow. Competitors are observed once through registration
// and running-app APIs; Atelier never changes or terminates another application.
import AppKit
import SwiftUI

struct AtelierCompetitor {
    let name: String
    let installed: Bool
    let running: Bool
    static func snapshot() -> [AtelierCompetitor] {
        [("Hammerspoon", "org.hammerspoon.Hammerspoon"), ("Hammerspoon 2", "net.tenshu.Hammerspoon-2")].map { name, id in
            AtelierCompetitor(name: name,
                installed: NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil,
                running: !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty)
        }
    }
}

@MainActor
@Observable
final class AtelierLaunch {
    static let shared = AtelierLaunch()
    private var startup = AtelierStartup()
    var phase: AtelierStartup.Phase { startup.phase }
    private(set) var competitors: [AtelierCompetitor] = []
    private(set) var accessibility = false
    private var permissionTimer: Timer?

    func begin() {
        guard phase == .idle else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        ConsoleCompletionEngine.shared.prewarm()
        competitors = AtelierCompetitor.snapshot()
        startup.begin(completed: SettingsManager.shared.hasCompletedOnboarding,
                      runningCompetitor: competitors.contains(where: \.running),
                      suppressWarning: AtelierPreferences.shared.bool("suppressCoexistenceWarning"))
        advance()
    }
    func completeOnboarding() {
        guard phase == .onboarding else { return }
        permissionTimer?.invalidate(); permissionTimer = nil
        SettingsManager.shared.hasCompletedOnboarding = true
        startup.completeOnboarding()
        AtelierWindows.shared.closeWelcome()
        advance()
    }
    private func advance() {
        switch phase {
        case .onboarding:
            accessibility = PermissionsManager.shared.check(.accessibility)
            AtelierWindows.shared.showWelcome()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.phase == .onboarding else { return }
                    let granted = PermissionsManager.shared.check(.accessibility)
                    let newlyGranted = granted && !self.accessibility
                    self.accessibility = granted
                    if newlyGranted { self.completeOnboarding() }
                }
            }
        case .conflict:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Another Hammerspoon is running"
            alert.informativeText = "\(competitors.filter(\.running).map(\.name).joined(separator: " and ")) may register the same shortcuts or change windows while Atelier runs. When switching fully to Atelier, disable its startup/login behavior and consider uninstalling it."
            alert.addButton(withTitle: "Continue Anyway")
            alert.addButton(withTitle: "Quit Atelier")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't warn again"
            NSApp.activate(ignoringOtherApps: true)
            let proceed = alert.runModal() == .alertFirstButtonReturn
            if proceed { AtelierPreferences.shared.set(alert.suppressionButton?.state == .on, for: "suppressCoexistenceWarning") }
            startup.resolveConflict(continueAnyway: proceed)
            advance()
        case .ready: ManagerManager.shared.start()
        case .quitting: NSApp.terminate(nil)
        case .idle: break
        }
    }
    func stop() { permissionTimer?.invalidate(); permissionTimer = nil }
}
