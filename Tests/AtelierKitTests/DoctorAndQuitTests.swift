import Client
import Foundation
import MacOS
import Synchronization
import Testing

@testable import AtelierKit

/// What the running app says of itself to `atelier doctor`, and quitting when asked.
@Suite struct DoctorAndQuitTests {
  private func report(_ atelier: Atelier) async throws -> AppReport {
    let reply = await atelier.reply(to: Request(name: "doctor"))
    #expect(reply.ok)
    return try JSONDecoder().decode(AppReport.self, from: Data(reply.output.utf8))
  }

  /// A Mac whose Space switches never take, with an Atelier that gives one
  /// half a second before giving up: a command that is running for long
  /// enough that a slow machine cannot arrive after it has ended, as it can
  /// with the 30 ms the other tests allow.
  private func withACommandThatStaysRunning() -> (FakeMac, Atelier) {
    let mac = FakeMac.oneDisplay(current: 1)
    mac.change { $0.ignoresSwitches = true }
    var patience = Patience.short
    patience.transition = .milliseconds(500)
    return (mac, Atelier(mac: mac, patience: patience))
  }

  @Test func theAppReportsItsBuildPermissionLoginAndConfiguration() async throws {
    let report = try await report(Atelier(FakeMac()))
    #expect(report.version == Build.version)
    #expect(report.build == Build.number)
    #expect(report.path == "/Applications/Atelier.app")
    #expect(report.hasAccessibility)
    #expect(report.login.status == "notRegistered")
    #expect(!report.login.needsAttention)
    #expect(report.configurationProblems.isEmpty)
  }

  @Test func aMissingPermissionAndAnUnapprovedLoginItemAreReportedAsTheyAre() async throws {
    let mac = FakeMac(hasAccessibility: false)
    mac.change { $0.loginItemStatus = .requiresApproval }
    let report = try await report(Atelier(mac))
    #expect(!report.hasAccessibility)
    #expect(report.login.status == "requiresApproval")
    #expect(report.login.needsAttention)
    #expect(report.login.advice != nil)
  }

  @Test func configurationProblemsInEffectAreReported() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "atelier-doctor-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "config.toml")
    try "theme = \"sepia\"\n".write(to: file, atomically: true, encoding: .utf8)
    let report = try await report(Atelier(FakeMac(), configFile: file))
    #expect(report.configurationProblems.map(\.location) == ["theme"])
    #expect(report.configurationFile?.hasSuffix("config.toml") == true)
  }

  @Test func doctorIsAQueryAndQuitStandsAlone() {
    #expect(Command(words: "doctor") == .doctor)
    #expect(Command.doctor.isQuery)
    #expect(Command(words: "quit") == .quit)
    #expect(Command.quit.words == "quit")
    #expect(Command(words: "quit now") == nil)
    #expect(Command(words: "") == nil)
  }

  @Test func askedOverTheSocketItAgreesAndLeavesTheEndingToWhoeverSendsTheReply() async {
    let mac = FakeMac.oneDisplay()
    let atelier = Atelier(mac)
    let reply = await atelier.reply(to: Request(name: "quit"))
    #expect(reply == Reply(ok: true, output: "Atelier is quitting."))
    #expect(mac.requests.isEmpty)
    // Nothing starts once Atelier is leaving.
    let next = await atelier.reply(to: Request(name: "desktops.new"))
    #expect(next == Reply(ok: false, output: AtelierError.busy.message, busy: true))
    #expect(mac.requests.isEmpty)
  }

  @Test func onlyBusyIsMarkedAsWorthAskingAgain() async {
    let reply = await Atelier(FakeMac()).reply(to: Request(name: "windows.close"))
    #expect(!reply.ok)
    #expect(reply.busy == nil)
  }

  @Test func anAskerThatNeverHeardBackFindsAtelierStillWorking() async {
    let mac = FakeMac.oneDisplay()
    let atelier = Atelier(mac)
    #expect(await atelier.reply(to: Request(name: "quit")).ok)
    await atelier.runner.reopen()
    let next = await atelier.reply(to: Request(name: "desktops.select", arguments: ["2"]))
    #expect(next.ok)
    #expect(mac.requests == ["switch to 2"])
  }

  @Test func aQuitThatCannotBeRefusedWaitsForTheCommandAndThenNothingStarts() async {
    let (mac, atelier) = withACommandThatStaysRunning()
    let command = Task {
      await atelier.reply(to: Request(name: "desktops.select", arguments: ["2"]))
    }
    #expect(await eventually { mac.requests == ["switch to 2"] })
    await atelier.prepareToQuit()
    // The command had its whole time, and ended as it would have anyway.
    #expect(await !command.value.ok)
    let next = await atelier.reply(to: Request(name: "desktops.select", arguments: ["3"]))
    #expect(next == Reply(ok: false, output: AtelierError.busy.message, busy: true))
    #expect(mac.requests == ["switch to 2"])
    // Asked again, as when `atelier quit` leads to the app's own ending, it returns at once.
    await atelier.prepareToQuit()
  }

  @Test func commandsThatKeepArrivingCannotPutTheEndingOff() async throws {
    // Closed from the moment the quit is asked for, not from when the wait ends:
    // otherwise a command arriving just as the running one finished could get
    // in ahead of the quit, and then another, without end.
    let workspace = Workspace(mac: FakeMac.oneDisplay(), stateFolder: nil, patience: .short)
    // The command says when it has the gate, and keeps it until told to go on.
    let started = AsyncStream.makeStream(of: Void.self)
    let gate = AsyncStream.makeStream(of: Void.self)
    let running = Task {
      try await workspace.run { _ throws(AtelierError) in
        started.continuation.yield()
        for await _ in gate.stream { break }
        return .changed
      }
    }
    for await _ in started.stream { break }
    let quitting = Task { await workspace.closeWhenIdle() }
    // The quit is waiting on the running command. Let that finish, and try
    // at once to start another: the gate is already shut.
    #expect(await eventually { await workspace.isClosed })
    gate.continuation.yield()
    #expect(try await running.value == .changed)
    await #expect(throws: AtelierError.busy) { try await workspace.run { _ in .changed } }
    await quitting.value
    await #expect(throws: AtelierError.busy) { try await workspace.run { _ in .changed } }
  }

  @Test func fromAKeyOrTheMenuItEndsAtOnce() async throws {
    let mac = FakeMac.oneDisplay()
    #expect(try await Atelier(mac).perform(.quit) == .changed)
    #expect(mac.requests == ["terminate"])
  }

  @Test func aRunningCommandIsNotCutShort() async {
    let (mac, atelier) = withACommandThatStaysRunning()
    Task { _ = await atelier.reply(to: Request(name: "desktops.select", arguments: ["2"])) }
    #expect(await eventually { mac.requests == ["switch to 2"] })
    let reply = await atelier.reply(to: Request(name: "quit"))
    #expect(reply == Reply(ok: false, output: AtelierError.busy.message, busy: true))
    #expect(!mac.requests.contains("terminate"))
  }

  /// That the hook follows the reply is how `serve` is written, one line after
  /// the other; this shows the hook runs, and with what.
  @Test func theServerHandsEachRequestAndReplyToItsHook() async throws {
    let path = "/tmp/atelier-tests-\(UUID().uuidString.prefix(8))/atelier.sock"
    let after = Mutex<[String]>([])
    try Server.start(path: path) { request in
      Reply(ok: true, output: "reply to \(request.name)")
    } afterReply: { request, reply, delivered in
      after.withLock { $0.append("\(request.name): \(reply.output), delivered: \(delivered)") }
    }
    #expect(try await Request(name: "quit").sent(to: path).output == "reply to quit")
    #expect(await eventually { !after.withLock(\.isEmpty) })
    #expect(after.withLock { $0 } == ["quit: reply to quit, delivered: true"])
  }
}
