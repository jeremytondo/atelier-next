// Private, nonmutating packaged probes run without onboarding, user preferences,
// or the real Space helper. Normal launches enforce one Atelier process.
import AppKit

@MainActor
enum AtelierCommandLine {
    static func run() {
        if CommandLine.arguments.contains("--version") { print(AtelierHost.version); exit(0) }
        let probe = CommandLine.arguments.contains("--self-test")
        let bootstrap = CommandLine.arguments.contains("--bootstrap-config")
        let lifecycle = CommandLine.arguments.contains("--lifecycle-test")
        if probe || bootstrap || lifecycle {
            guard let directory = ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"], directory.hasPrefix("/") else {
                fail("Probes require a private absolute ATELIER_CONFIG_DIR")
            }
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            do {
                if lifecycle { try AtelierLifecycleProbe.run(); exit(0) }
                if bootstrap { try AtelierHost.prepare(); exit(0) }
                let engine = JSEngine.shared
                try engine.resetContext()
                try AtelierHost.install(in: engine)
                engine["atelierSelfTestXPC"] = !CommandLine.arguments.contains("--self-test-no-xpc")
                try engine.evalFromURL(AtelierHost.resources.appendingPathComponent("Atelier/self-test.js"))
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline && engine.eval("globalThis.atelierSelfTestDone === true") as? Bool != true {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                let success = engine.eval("globalThis.atelierSelfTestDone === true && !globalThis.atelierSelfTestError") as? Bool == true
                let detail = engine.eval("globalThis.atelierSelfTestError || 'HS2 runtime probe timed out'") as? String ?? "Runtime probe failed"
                engine.shutdown()
                guard success else { fail(detail) }
                print("HS2 runtime self-test passed"); exit(0)
            } catch { fail(error.localizedDescription) }
        }
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.elevenideas.Atelier")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: []); exit(0)
        }
    }
    static func fail(_ message: String) -> Never {
        for entry in HammerspoonLog.shared.entries(minimumLevel: .Debug).suffix(30) {
            FileHandle.standardError.write(Data((entry.msg + "\n").utf8))
        }
        FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
    }
}
