// Same-named adapter for the retained HS2 engine, logger, and SpoonManager.
// The upstream protocol still requires obsolete shell properties; they are
// inert compatibility members, never user-facing behavior preferences.
import Foundation

@MainActor
final class SettingsManager: SettingsManagerProtocol {
    static let shared = SettingsManager()
    var configLocation: URL {
        get { (try? AtelierHost.configurationURL()) ?? AtelierHost.resources.appendingPathComponent("unavailable-config.js") }
        set { /* HS2 cannot redirect Atelier's canonical configuration. */ }
    }
    var consoleHistoryLength = 100
    var relaunchOnReload: Bool { get { false } set {} }
    var hasCompletedOnboarding: Bool {
        get { AtelierPreferences.shared.bool("onboardingCompleted") }
        set { AtelierPreferences.shared.set(newValue, for: "onboardingCompleted") }
    }
    var garbageLoggingEnabled: Bool { get { false } set {} }
    func removeAllDelegates() {}
    func resetToDefaults() { consoleHistoryLength = 100 }
}

// Development overrides put native UI state beside the private configuration,
// avoiding writes to the real application's UserDefaults during bundle probes.
@MainActor
final class AtelierPreferences {
    static let shared = AtelierPreferences()
    private let file: URL?
    private var values: [String: Bool]

    init() {
        if ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"] != nil {
            file = try? AtelierHost.configurationURL().deletingLastPathComponent().appendingPathComponent(".atelier-ui.json")
        } else { file = nil }
        values = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
    }
    func bool(_ key: String) -> Bool {
        if ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"] != nil { return values[key] ?? false }
        return UserDefaults.standard.bool(forKey: "Atelier." + key)
    }
    func set(_ value: Bool, for key: String) {
        if ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"] != nil {
            values[key] = value
            do {
                guard let file else { throw CocoaError(.fileWriteInvalidFileName) }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(values).write(to: file, options: .atomic)
            } catch { AtelierHost.presentError(error, action: "Save welcome preferences") }
        } else { UserDefaults.standard.set(value, forKey: "Atelier." + key) }
    }
}
