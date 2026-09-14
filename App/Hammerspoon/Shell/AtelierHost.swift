// Native services remain usable without JavaScript. Failures here are reported
// independently of configuration/defaults errors and never tear down scripts.
import AppKit
import JavaScriptCore
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class AtelierStatus {
    static let shared = AtelierStatus()
    var defaultsState = "Paused"
    var defaultsError = ""
    var configurationError = ""
    var nativeError = ""
    var configurationLoaded = false
    var state: String {
        if !configurationError.isEmpty { return "Configuration error" }
        if !ManagerManager.shared.authorized { return "Waiting for welcome setup" }
        return configurationLoaded ? "Defaults: \(defaultsState)" : "Loading configuration"
    }
    func beginConfiguration() {
        configurationLoaded = false
        configurationError = ""
        defaultsState = "Paused"
        defaultsError = ""
    }
}

@MainActor
enum AtelierHost {
    static var probeHelper = false
    static var resources: URL { Bundle.main.resourceURL! }
    static func configurationURL() throws -> URL {
        try AtelierConfiguration.location(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
    }
    static var version: String {
        let pin = (try? Data(contentsOf: resources.appendingPathComponent("Hammerspoon2-version.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return "Atelier \(Bundle.main.object(forInfoDictionaryKey: "AtelierBuildVersion") as? String ?? "local") (HS2 \(pin?["version"] as? String ?? "unknown"))"
    }
    static func prepare() throws {
        try AtelierConfiguration.seed(at: configurationURL(), from: resources.appendingPathComponent("DefaultConfig/init.js"))
    }
    static func install(in engine: any JSEngineProtocol, generation: UUID? = nil) throws {
        var engine = engine
        engine["atelierHost"] = [
            "helper": Bundle.main.bundleURL.appendingPathComponent(probeHelper ? "Contents/Helpers/atelier-config" : "Contents/Helpers/atelier-engine").path,
            "helperArguments": probeHelper ? ["--self-test-helper"] : [],
            "bundleID": Bundle.main.bundleIdentifier ?? "com.elevenideas.Atelier",
            "modules": resources.appendingPathComponent("Atelier").path,
            "version": version,
        ]
        let status: @convention(block) (String, String) -> Void = { state, error in
            if let generation, !ManagerManager.shared.acceptsStatus(generation) { return }
            AtelierStatus.shared.defaultsState = state
            AtelierStatus.shared.defaultsError = error
        }
        let login: @convention(block) (Bool) -> Void = { enabled in
            do {
                if enabled && SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                } else if !enabled && SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            } catch { presentError(error, action: "Launch at login") }
        }
        engine["_atelierStatus"] = status
        engine["_atelierLogin"] = login
        engine.eval("atelierHost.status = _atelierStatus; atelierHost.setLogin = _atelierLogin;")
        let encoded = String(data: try JSONEncoder().encode(resources.appendingPathComponent("Atelier/index.js").path), encoding: .utf8)!
        engine.eval("globalThis.atelier = require(\(encoded)).create(hs, atelierHost);")
        guard engine.eval("typeof atelier === 'object' && typeof atelier.start === 'function'") as? Bool == true else {
            throw NSError(domain: "Atelier.Runtime", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled Atelier runtime could not load. Reinstall Atelier; your configuration will be preserved."])
        }
    }
    static func presentError(_ error: Error, action: String) {
        AtelierStatus.shared.nativeError = "\(action): \(error.localizedDescription)"
        AKError(AtelierStatus.shared.nativeError)
    }
    static func open(_ url: URL, action: String) {
        if !NSWorkspace.shared.open(url) {
            presentError(NSError(domain: "Atelier.Open", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS could not open \(url.path.isEmpty ? url.absoluteString : url.path)"]), action: action)
        }
    }
    static func openConfiguration() {
        do { try prepare(); open(try configurationURL(), action: "Open Configuration") }
        catch { presentError(error, action: "Open Configuration") }
    }
    static func accessibilityHelp() {
        if AtelierLaunch.shared.phase == .onboarding {
            AtelierWindows.shared.showWelcome()
        } else if PermissionsManager.shared.check(.accessibility) {
            try? ManagerManager.shared.reload()
        } else {
            AtelierWindows.shared.showPermissions()
            PermissionsManager.shared.request(.accessibility)
        }
    }
    static func openReference() { open(resources.appendingPathComponent("Configuration.md"), action: "Configuration Reference") }
    static func openReleases() { open(URL(string: "https://github.com/jeremytondo/atelier-next/releases")!, action: "Open releases") }
    static func diagnostics() -> [String: Any] {
        let manager = ManagerManager.shared
        let status = AtelierStatus.shared
        var result: [String: Any] = [
            "version": version, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "configuration": (try? configurationURL().path) ?? "Unavailable",
            "contextAvailable": manager.engine.hasContext(), "configurationLoaded": status.configurationLoaded,
            "status": status.state, "configurationError": status.configurationError,
            "nativeError": status.nativeError, "defaultsError": status.defaultsError,
            "accessibility": PermissionsManager.shared.check(.accessibility),
        ]
        if manager.engine.hasContext(),
           let json = manager.engine.eval("JSON.stringify(globalThis.atelier && atelier.status())") as? String,
           let data = json.data(using: .utf8), let runtime = try? JSONSerialization.jsonObject(with: data) {
            result["runtime"] = runtime
        }
        return result
    }
    static func exportDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Atelier-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONSerialization.data(withJSONObject: diagnostics(), options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { presentError(error, action: "Export Diagnostics") }
    }
}
