// Atelier owns app lifetime and windows. HS2 supplies the runtime and Console
// in this target/process. Sparkle stays linked, with no updater instantiated.
import AppKit
import SwiftUI

@MainActor
final class AtelierAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AtelierLaunch.shared.begin()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ManagerManager.shared.shutdown() else { return .terminateCancel }
        AtelierLaunch.shared.stop()
        return .terminateNow
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where !url.isFileURL { URLEventDispatcher.shared.dispatch(url) }
    }
}

@main
struct AtelierApp: App {
    @NSApplicationDelegateAdaptor(AtelierAppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    init() {
        AtelierCommandLine.run()
        // All scenes suppress automatic windows. Queue startup independently
        // of scene appearance; the coordinator guards both entry paths.
        DispatchQueue.main.async { AtelierLaunch.shared.begin() }
    }
    var body: some Scene {
        MenuBarExtra("Atelier", systemImage: "square.stack.3d.up") { AtelierMenu() }
        Window("Atelier Console", id: "console") { ConsoleView() }
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
            .handlesExternalEvents(matching: ["openConsole", "closeConsole"])
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .appInfo) {
                    Button("About Atelier") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "about") }
                }
                CommandMenu("Configuration") {
                    Button("Open Configuration", action: AtelierHost.openConfiguration)
                    Button("Reload Config") { try? ManagerManager.shared.reload() }
                }
            }
        Window("About Atelier", id: "about") { AboutView() }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
            .handlesExternalEvents(matching: [])
    }
}

struct AtelierMenu: View {
    @State private var status = AtelierStatus.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(status.state)
        ForEach([status.configurationError, status.defaultsError, status.nativeError].filter { !$0.isEmpty }, id: \.self) { error in
            Text(error).lineLimit(4)
        }
        Divider()
        Button("Open Configuration", action: AtelierHost.openConfiguration)
        Button("Configuration Reference", action: AtelierHost.openReference)
        Button("Reload Config") { try? ManagerManager.shared.reload() }
            .disabled(!ManagerManager.shared.authorized)
        if status.defaultsState == "Running" || status.defaultsState == "Starting" {
            Button("Pause Atelier Defaults") { ManagerManager.shared.pause() }
        } else {
            Button("Resume Atelier Defaults") { ManagerManager.shared.resume() }
                .disabled(!ManagerManager.shared.engine.hasContext())
        }
        Divider()
        Button("Console") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "console") }
        Button("Export Diagnostics", action: AtelierHost.exportDiagnostics)
        Button("Accessibility Help", action: AtelierHost.accessibilityHelp)
        Button("Permissions") { AtelierWindows.shared.showPermissions() }
        Button("Download Atelier Releases", action: AtelierHost.openReleases)
        Divider()
        Button("Quit Atelier") { NSApp.terminate(nil) }
    }
}
