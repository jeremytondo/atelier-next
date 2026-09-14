import Foundation
import Testing
@testable import AtelierShellCore

@Test func canonicalConfiguration() throws {
    let home = URL(fileURLWithPath: "/private/test-home")
    let cases: [([String: String], String)] = [
        ([:], "/private/test-home/.config/atelier/init.js"),
        (["XDG_CONFIG_HOME": "/private/xdg"], "/private/xdg/atelier/init.js"),
        (["XDG_CONFIG_HOME": "relative"], "/private/test-home/.config/atelier/init.js"),
        (["ATELIER_CONFIG_DIR": "/private/isolated", "XDG_CONFIG_HOME": "/private/xdg"], "/private/isolated/init.js"),
    ]
    for (environment, expected) in cases {
        #expect(try AtelierConfiguration.location(environment: environment, home: home).path == expected)
    }
    #expect(throws: (any Error).self) {
        try AtelierConfiguration.location(environment: ["ATELIER_CONFIG_DIR": "relative"], home: home)
    }
}

@Test func seedingPreservesEveryExistingConfiguration() throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("atelier-shell-\(UUID())")
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    let template = directory.appendingPathComponent("default.js")
    try Data("atelier.start();".utf8).write(to: template)
    let config = directory.appendingPathComponent("config/init.js")
    try AtelierConfiguration.seed(at: config, from: template)
    #expect(try String(contentsOf: config, encoding: .utf8) == "atelier.start();")
    for content in ["", "syntax error {{{", "// my config"] {
        try Data(content.utf8).write(to: config)
        try Data("new defaults".utf8).write(to: template)
        try AtelierConfiguration.seed(at: config, from: template)
        #expect(try String(contentsOf: config, encoding: .utf8) == content)
    }
    try files.removeItem(at: config)
    try Data("invalid legacy TOML".utf8).write(to: config.deletingLastPathComponent().appendingPathComponent("config.toml"))
    try AtelierConfiguration.seed(at: config, from: template)
    #expect(try String(contentsOf: config, encoding: .utf8) == "new defaults")
}

@Test func onboardingAndConflictGateConfigurationExactlyOnce() {
    for completed in [false, true] {
        for running in [false, true] {
            for suppressed in [false, true] {
                var startup = AtelierStartup()
                startup.begin(completed: completed, runningCompetitor: running, suppressWarning: suppressed)
                if !completed { #expect(startup.phase == .onboarding); startup.completeOnboarding() }
                if running && !suppressed { #expect(startup.phase == .conflict); startup.resolveConflict(continueAnyway: true) }
                #expect(startup.phase == .ready)
                startup.completeOnboarding()
                startup.begin(completed: false, runningCompetitor: true, suppressWarning: false)
                startup.resolveConflict(continueAnyway: false)
                #expect(startup.phase == .ready)
            }
        }
    }
    var cancelled = AtelierStartup()
    cancelled.begin(completed: true, runningCompetitor: true, suppressWarning: false)
    cancelled.resolveConflict(continueAnyway: false)
    #expect(cancelled.phase == .quitting)
}
