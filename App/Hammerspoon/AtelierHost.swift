// Atelier's integration with the upstream app lifecycle. HS2 owns the JS engine,
// console, configuration reload, and automation APIs; feature policy lives in JS.
import AppKit
import ApplicationServices
import JavaScriptCore
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class AtelierStatus {
    static let shared = AtelierStatus()
    var state = "Loading configuration"
    var error = ""
}

@MainActor
enum AtelierHost {
    static var configURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["ATELIER_CONFIG_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path).appendingPathComponent("init.js")
        }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("atelier/init.js")
    }
    static var resources: URL { Bundle.main.resourceURL! }
    static var version: String {
        "Atelier \(Bundle.main.object(forInfoDictionaryKey: "AtelierBuildVersion") as? String ?? "local") (Hammerspoon 2 0.0.12)"
    }
    static func commandLine() {
        if CommandLine.arguments.contains("--version") { print(version); exit(0) }
        if CommandLine.arguments.contains("--self-test") {
            guard let directory = ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"], directory.hasPrefix("/") else {
                FileHandle.standardError.write(Data("Self-test requires a private ATELIER_CONFIG_DIR\n".utf8)); exit(1)
            }
            // This is a headless runtime probe: it loads no user config, registers
            // no hotkeys, and never starts the native Space helper.
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            do {
                let engine = JSEngine.shared
                try engine.resetContext()
                try install(in: engine)
                try engine.evalFromURL(resources.appendingPathComponent("Atelier/self-test.js"))
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline && engine.eval("globalThis.atelierSelfTestDone === true") as? Bool != true {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                let success = engine.eval("globalThis.atelierSelfTestDone === true && !globalThis.atelierSelfTestError") as? Bool == true
                let detail = engine.eval("globalThis.atelierSelfTestError || 'HS2 runtime probe timed out'") as? String ?? "Runtime probe failed"
                engine.shutdown()
                guard success else { throw NSError(domain: "Atelier.SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
                print("HS2 runtime self-test passed"); exit(0)
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.elevenideas.Atelier")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: []); exit(0)
        }
    }
    static func prepare() throws {
        let settings = SettingsManager.shared
        if ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"] != nil {
            settings.configLocation = configURL
        }
        let file = settings.configLocation
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/atelier-config")
            let process = Process()
            let pipe = Pipe()
            process.executableURL = tool
            process.arguments = ["--bootstrap", directory.path]
            process.standardError = pipe
            try process.run()
            let errors = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "Atelier", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: errors, as: UTF8.self)])
            }
        }
    }
    static func install(in engine: any JSEngineProtocol) throws {
        var engine = engine
        engine["atelierHost"] = [
            "helper": Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/atelier-engine").path,
            "bundleID": Bundle.main.bundleIdentifier ?? "com.elevenideas.Atelier",
            "modules": resources.appendingPathComponent("Atelier").path,
            "version": version,
        ]
        let status: @convention(block) (String, String) -> Void = { state, error in
            AtelierStatus.shared.state = state
            AtelierStatus.shared.error = error
        }
        let login: @convention(block) (Bool) -> Void = { enabled in
            do {
                if enabled && SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                } else if !enabled && SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            } catch { AKError("Launch at login: \(error.localizedDescription)") }
        }
        engine["_atelierStatus"] = status
        engine["_atelierLogin"] = login
        engine.eval("atelierHost.status = _atelierStatus; atelierHost.setLogin = _atelierLogin;")
        let path = resources.appendingPathComponent("Atelier/index.js").path
        let encoded = String(data: try JSONEncoder().encode(path), encoding: .utf8)!
        engine.eval("globalThis.atelier = require(\(encoded)).create(hs, atelierHost);")
    }
    static func stop(_ engine: any JSEngineProtocol) {
        engine.eval("if (globalThis.atelier) atelier.stop();")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && engine.eval("!!(globalThis.atelier && atelier.helperRunning())") as? Bool == true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
    static func showError(_ error: Error) {
        stop(ManagerManager.shared.engine)
        ManagerManager.shared.engine.shutdown()
        AtelierStatus.shared.state = "Configuration error"
        AtelierStatus.shared.error = error.localizedDescription
        AKError("Atelier: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "Atelier could not load your configuration"
        alert.informativeText = error.localizedDescription + "\nEdit your configuration and choose Reload Config."
        alert.runModal()
    }
    static func openConfiguration() { NSWorkspace.shared.open(SettingsManager.shared.configLocation) }
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    static func openReference() { NSWorkspace.shared.open(resources.appendingPathComponent("Configuration.md")) }
    static func openReleases() { NSWorkspace.shared.open(URL(string: "https://github.com/jeremytondo/atelier-next/releases")!) }
    static func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Atelier-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let status = JSEngine.shared.eval("JSON.stringify(atelier.status())") as? String ?? "{}"
        do { try Data(status.utf8).write(to: url, options: .atomic) }
        catch { showError(error) }
    }
}
