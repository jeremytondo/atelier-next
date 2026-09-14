// Native welcome and permission status are shell UI; automation behavior stays
// in JavaScript. Only active onboarding detects permission grants automatically.
import AppKit
import SwiftUI

@MainActor
final class AtelierWindows {
    static let shared = AtelierWindows()
    private var welcome: NSWindow?
    private var permissions: NSWindow?
    private func show<V: View>(_ title: String, view: V) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
    func showWelcome() {
        if let welcome { welcome.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { welcome = show("Welcome to Atelier", view: AtelierWelcomeView()) }
    }
    func closeWelcome() { welcome?.close(); welcome = nil }
    func showPermissions() {
        if let permissions { permissions.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { permissions = show("Atelier Permissions", view: AtelierPermissionsView()) }
    }
}

struct AtelierWelcomeView: View {
    @State private var launch = AtelierLaunch.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Atelier").font(.title).bold()
            Text("Atelier adds keyboard controls for Desktops, Groups, and Quick Apps. Customize its behavior in your JavaScript configuration.")
            Text((try? AtelierHost.configurationURL().path) ?? "Configuration path unavailable").font(.callout.monospaced()).textSelection(.enabled)
            Text("Accessibility lets Atelier control windows and shortcuts. Your configuration will start after you grant access, or you can continue without it.")
            ForEach(launch.competitors.filter { $0.installed && !$0.running }, id: \.name) { competitor in
                Text("\(competitor.name) is installed but stopped. When switching to Atelier, disable its startup/login behavior and consider uninstalling it.").font(.callout)
            }
            HStack {
                Button("Quit Atelier") { NSApp.terminate(nil) }
                Spacer()
                if launch.accessibility {
                    Button("Continue") { launch.completeOnboarding() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue Without Access") { launch.completeOnboarding() }
                    Button("Grant Accessibility") { PermissionsManager.shared.request(.accessibility) }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 520).fixedSize(horizontal: false, vertical: true)
    }
}

struct AtelierPermissionsView: View {
    @State private var states: [PermissionsType: PermissionsState] = [:]
    private func refresh() { states = Dictionary(uniqueKeysWithValues: PermissionsType.allCases.map { ($0, PermissionsManager.shared.state($0)) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions").font(.title).bold()
            Text("Atelier Defaults need Accessibility. Other permissions depend on the HS2 scripts you choose to run.")
            ForEach(PermissionsType.allCases, id: \.rawValue) { permission in
                HStack {
                    VStack(alignment: .leading) {
                        Text(permission.displayName)
                        Text(permission.permissionDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(states[permission] == .trusted ? "Granted" : "Not granted")
                    Button("Open Settings") { AtelierHost.open(permission.settingsURL, action: "Open permission settings") }
                }
            }
            Button("Check Accessibility and Reload Config") {
                refresh()
                if PermissionsManager.shared.check(.accessibility) { try? ManagerManager.shared.reload() }
                else { PermissionsManager.shared.request(.accessibility) }
            }
        }.padding(24).frame(width: 600).fixedSize(horizontal: false, vertical: true).onAppear { refresh() }
    }
}
