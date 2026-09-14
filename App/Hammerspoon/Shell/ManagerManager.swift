// HS2's engine and Console call this same-named adapter. It is the sole owner
// of context replacement and defaults cleanup. Configuration exceptions retain
// the context; a helper that will not exit prevents replacement, preserving the
// handle needed to retry shutdown without racing the Space-operation lock.
import AppKit
import JavaScriptCore
import Observation

@MainActor
@Observable
final class ManagerManager {
    static let shared = ManagerManager()
    let engine: any JSEngineProtocol = JSEngine.shared
    private var defaults: JSValue?
    private var generation = UUID()
    private var reloadQueued = false
    private(set) var authorized = false
    private(set) var transitioning = false

    func start() {
        guard !authorized else { return }
        authorized = true
        try? reload()
    }

    func reload() throws {
        guard authorized else { return }
        // hs.reload() can enter from a JS callback. Unwind the evaluation before
        // destroying its context. Coalesce requests from that same turn.
        if JSContext.current() != nil {
            guard !reloadQueued else { return }
            reloadQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reloadQueued = false
                try? self.reload()
            }
            return
        }
        guard !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        do {
            try stopDefaults()
            defaults = nil
            generation = UUID()
            AtelierStatus.shared.beginConfiguration()
            try AtelierHost.prepare()
            try engine.resetContext()
            try AtelierHost.install(in: engine, generation: generation)
            defaults = engine["atelier"] as? JSValue
            let file = try AtelierHost.configurationURL()
            guard FileManager.default.changeCurrentDirectoryPath(file.deletingLastPathComponent().path) else {
                throw CocoaError(.fileReadNoPermission)
            }
            try engine.evalFromURL(file)
            AtelierStatus.shared.configurationLoaded = true
        } catch {
            AtelierStatus.shared.configurationError = error.localizedDescription
            AKError("Atelier configuration: \(error.localizedDescription)")
            throw error
        }
    }

    func acceptsStatus(_ value: UUID) -> Bool { value == generation }

    func pause() {
        guard !transitioning else { return }
        do { try stopDefaults() }
        catch { AtelierHost.presentError(error, action: "Pause Atelier Defaults") }
    }

    func resume() {
        guard !transitioning, let defaults else { return }
        // The JS API reports and rejects startup failures after cleaning up its
        // own objects. The native shell only observes that result.
        let report: @convention(block) (JSValue) -> Void = { error in AKError("Atelier defaults: \(error)") }
        defaults.invokeMethod("start", withArguments: [])?.invokeMethod("catch", withArguments: [report])
    }

    private func stopDefaults() throws {
        guard let defaults else { return }
        defaults.invokeMethod("stop", withArguments: [])
        let deadline = Date().addingTimeInterval(3)
        while defaults.invokeMethod("helperRunning", withArguments: [])?.toBool() == true {
            guard Date() < deadline else {
                throw NSError(domain: "Atelier.Lifecycle", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The previous helper is still stopping. Reload was cancelled to protect your Desktops. Try Reload Config again after it exits."])
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func shutdown() -> Bool {
        guard !transitioning else { return false }
        transitioning = true
        defer { transitioning = false }
        do {
            try stopDefaults()
            defaults = nil
            generation = UUID()
            engine.shutdown()
            return true
        } catch {
            AtelierHost.presentError(error, action: "Quit Atelier")
            return false
        }
    }
}
