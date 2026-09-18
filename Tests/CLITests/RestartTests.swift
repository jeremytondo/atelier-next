import Client
import Foundation
import Synchronization
import Testing

@testable import CLI

/// `atelier quit` and `atelier restart` against an app that is only described:
/// each test says how the app answers each request in turn, and what was
/// opened is recorded.
@Suite struct RestartTests {
  private static let installed = InstalledApp(
    path: "/Applications/Atelier.app", version: Build.version, build: Build.number)

  private final class World: Sendable {
    let answers: Mutex<[Result<Reply, SocketError>]>
    let sent = Mutex<[String]>([])
    let opened = Mutex<[String]>([])

    init(_ answers: [Result<Reply, SocketError>]) {
      self.answers = Mutex(answers)
    }

    /// The last answer repeats, so a state that lasts needs saying once.
    func send(_ request: Request) throws(SocketError) -> Reply {
      sent.withLock { $0.append(request.name) }
      return try answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }.get()
    }

    func restarting(installed: InstalledApp? = RestartTests.installed, opens: Bool = true)
      -> Restarting
    {
      Restarting(
        send: { request throws(SocketError) in try self.send(request) },
        installedApp: { installed },
        open: { path in
          self.opened.withLock { $0.append(path) }
          return opens
        }, pause: {}, patience: 5)
    }

    var requests: [String] { sent.withLock { $0 } }
    var openedApps: [String] { opened.withLock { $0 } }
  }

  private typealias Answer = Result<Reply, SocketError>

  private let agreed = Answer.success(Reply(ok: true, output: "Atelier is quitting."))
  private let busy = Answer.success(Reply(ok: false, output: "Busy.", busy: true))
  private let gone = Answer.failure(.notRunning)

  /// A running app's answer to `doctor`.
  private func app(
    build: String = Build.number, path: String = "/Applications/Atelier.app"
  ) -> Answer {
    let report = AppReport(
      version: Build.version, build: build, path: path, hasAccessibility: true,
      login: AppReport.Login(
        status: "enabled", needsAttention: false, summary: "Atelier opens at login.", advice: nil),
      configurationFile: nil, configurationProblems: [])
    return .success(
      Reply(ok: true, output: String(decoding: try! JSONEncoder().encode(report), as: UTF8.self)))
  }

  private func failure(_ body: () throws -> some Any) -> String? {
    #expect(throws: Failure.self) { _ = try body() }?.description
  }

  @Test func anAtelierThatWasClosedStaysClosed() throws {
    let world = World([gone])
    #expect(
      try world.restarting().run() == "Atelier is not running, so there is nothing to restart.")
    #expect(world.openedApps.isEmpty)
    #expect(world.requests == ["quit"])
  }

  @Test func aRunningAtelierQuitsAndComesBackAsTheInstalledBuild() throws {
    let world = World([agreed, app(), gone, app()])
    #expect(try world.restarting().run() == "Atelier restarted as build \(Build.description).")
    #expect(world.openedApps == ["/Applications/Atelier.app"])
    // Opened only once the old one had stopped answering.
    #expect(world.requests == ["quit", "doctor", "doctor", "doctor"])
  }

  @Test func aCommandInProgressIsWaitedForNotCutShort() throws {
    let world = World([busy, busy, agreed, gone, app()])
    #expect(try world.restarting().run().hasPrefix("Atelier restarted"))
    #expect(world.requests.prefix(3) == ["quit", "quit", "quit"])
  }

  @Test func anAtelierThatStaysBusyIsLeftRunning() {
    let world = World([busy])
    #expect(failure { try world.restarting().run() }?.contains("stayed busy") == true)
    #expect(world.openedApps.isEmpty)
  }

  @Test func aRefusalThatIsNotBusyIsSaidAtOnceNotRetried() {
    // As from an Atelier too old to know the request.
    let world = World([.success(Reply(ok: false, output: "Atelier has no request quit."))])
    #expect(
      failure { try world.restarting().run() }
        == "Atelier would not quit: Atelier has no request quit.")
    #expect(world.requests == ["quit"])
    #expect(world.openedApps.isEmpty)
  }

  @Test func anAtelierThatWasBusyAndThenWentIsStillOpenedAgain() throws {
    let world = World([busy, gone, gone, app()])
    #expect(try world.restarting().run().hasPrefix("Atelier restarted"))
    #expect(world.openedApps == ["/Applications/Atelier.app"])
  }

  @Test func anAtelierThatWillNotGoIsNotOpenedASecondTime() {
    let world = World([agreed, app()])
    #expect(failure { try world.restarting().run() }?.contains("still running") == true)
    #expect(world.openedApps.isEmpty)
  }

  @Test func failuresToOpenAndToComeBackAreSaidAsTheyAre() {
    let refused = World([agreed, gone])
    #expect(
      failure { try refused.restarting(opens: false).run() }?.contains("macOS would not open")
        == true)
    let silent = World([agreed, gone])
    #expect(failure { try silent.restarting().run() }?.contains("not answering properly") == true)
    #expect(silent.openedApps == ["/Applications/Atelier.app"])
    // Something answers, and not with a report: that is not a restart either.
    let garbled = World([agreed, gone, .success(Reply(ok: true, output: "{}"))])
    #expect(failure { try garbled.restarting().run() }?.contains("not answering properly") == true)
  }

  @Test func anotherBuildOrAnotherAppAnsweringIsNotCalledARestart() {
    let otherBuild = World([agreed, gone, app(build: "older")])
    #expect(
      failure { try otherBuild.restarting().run() }?.contains("what is running now is build")
        == true)
    let otherApp = World([agreed, gone, app(path: "/Users/someone/dev/Atelier.app")])
    #expect(
      failure { try otherApp.restarting().run() }?.contains("/Users/someone/dev/Atelier.app")
        == true)
  }

  @Test func withNoInstalledAppARunningAtelierIsLeftRunning() {
    let world = World([app()])
    #expect(
      failure { try world.restarting(installed: nil).run() }?.contains("was left running") == true)
    // It was never asked to quit.
    #expect(!world.requests.contains("quit"))
    #expect(world.openedApps.isEmpty)
  }

  @Test func withNoInstalledAppAndNothingRunningThereIsNothingToRestart() throws {
    let world = World([gone])
    #expect(
      try world.restarting(installed: nil).run()
        == "Atelier is not running, so there is nothing to restart.")
    #expect(!world.requests.contains("quit"))
  }

  @Test func quitWaitsOutACommandAndSaysWhenNothingWasRunning() throws {
    let waiting = World([busy, agreed])
    #expect(try waiting.restarting().askToQuit())
    #expect(waiting.requests == ["quit", "quit"])
    #expect(try !World([gone]).restarting().askToQuit())
  }
}
