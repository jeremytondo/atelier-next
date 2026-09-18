import Client
import Foundation
import Testing

@testable import CLI

/// What `atelier doctor` makes of what it finds. Nothing here reaches a
/// running Atelier: the app's answer is handed in.
@Suite struct DoctorTests {
  private let matching = InstalledApp(
    path: "/Applications/Atelier.app", version: Build.version, build: Build.number)

  private func report(
    build: String = Build.number, hasAccessibility: Bool = true, login: String = "enabled",
    needsAttention: Bool = false, problems: [AppReport.Problem] = []
  ) -> AppReport {
    AppReport(
      version: Build.version, build: build, path: "/Applications/Atelier.app",
      hasAccessibility: hasAccessibility,
      login: AppReport.Login(
        status: login, needsAttention: needsAttention, summary: "Login summary.",
        advice: needsAttention ? "Login advice." : nil),
      configurationFile: "~/.config/atelier/config-next.toml", configurationProblems: problems)
  }

  private func diagnosis(_ app: Diagnosis.App, installed: InstalledApp?) -> Diagnosis {
    Diagnosis(commandPath: "/opt/homebrew/bin/atelier", installed: installed, app: app)
  }

  @Test func aHealthyInstallationHasNoProblems() {
    let diagnosis = diagnosis(.running(report()), installed: matching)
    #expect(diagnosis.problems.isEmpty)
    #expect(diagnosis.text.hasSuffix("Everything checks out."))
    #expect(diagnosis.text.contains("Accessibility  granted"))
    #expect(diagnosis.json.contains("\"app\" : \"running\""))
  }

  @Test func anAppThatIsNotInstalledIsToldApartFromOneThatIsNotRunning() {
    let absent = diagnosis(.notRunning, installed: nil)
    #expect(absent.problems.count == 2)
    #expect(absent.problems[0].hasPrefix("No Atelier.app was found"))
    #expect(absent.problems[1].hasPrefix("Atelier is not running"))
    #expect(absent.text.contains("Installed app  none found"))
    let closed = diagnosis(.notRunning, installed: matching)
    #expect(closed.problems.count == 1)
    #expect(closed.problems[0].hasPrefix("Atelier is not running"))
  }

  @Test func aHealthyAppRunningWithNoneInstalledIsNotCalledHealthy() {
    // As when only a build from a source checkout is running.
    let diagnosis = diagnosis(.running(report()), installed: nil)
    #expect(diagnosis.problems.count == 1)
    #expect(diagnosis.problems[0].hasPrefix("No Atelier.app was found"))
    #expect(!diagnosis.text.contains("Everything checks out."))
  }

  @Test(arguments: [Diagnosis.App.notRunning, .unreachable("It did not send a complete reply.")])
  func checksOnlyTheAppCanMakeAreNeverReportedAsPassed(app: Diagnosis.App) {
    let diagnosis = diagnosis(app, installed: matching)
    for check in ["Accessibility", "Open at login", "Configuration"] {
      #expect(
        diagnosis.text.contains(
          "\(check.padding(toLength: 15, withPad: " ", startingAt: 0))not checked"))
    }
    #expect(!diagnosis.text.contains("granted"))
    #expect(!diagnosis.text.contains("Everything checks out."))
    #expect(!diagnosis.json.contains("\"running\" :"))
  }

  @Test func anAppThatDoesNotAnswerIsToldApartFromOneThatIsNotRunning() {
    let diagnosis = diagnosis(
      .unreachable("Atelier did not send a complete reply."), installed: matching)
    #expect(diagnosis.text.contains("Running app    not answering"))
    #expect(diagnosis.problems.count == 1)
    #expect(diagnosis.problems[0].contains("did not give a report: Atelier did not send"))
    #expect(diagnosis.json.contains("\"app\" : \"unreachable\""))
  }

  @Test func mismatchedBuildsAreNamedOnBothSides() {
    let stale = diagnosis(.running(report(build: "older")), installed: matching)
    #expect(stale.problems.count == 1)
    #expect(stale.problems[0].hasPrefix("The running app is build \(Build.version) (older)"))
    #expect(stale.problems[0].contains("atelier restart"))
    let other = InstalledApp(path: "/Applications/Atelier.app", version: "9.9.9", build: "1")
    let foreign = diagnosis(.running(report()), installed: other)
    #expect(foreign.problems.count == 1)
    #expect(foreign.problems[0].hasPrefix("The installed app is build 9.9.9 (1)"))
  }

  @Test func theSameBuildRunningFromSomewhereElseIsNotTheInstalledApp() {
    // Builds from a source checkout all call themselves the same thing.
    let elsewhere = AppReport(
      version: Build.version, build: Build.number, path: "/Users/someone/dev/Atelier.app",
      hasAccessibility: true,
      login: AppReport.Login(
        status: "enabled", needsAttention: false, summary: "Login summary.", advice: nil),
      configurationFile: nil, configurationProblems: [])
    let diagnosis = diagnosis(.running(elsewhere), installed: matching)
    #expect(diagnosis.problems.count == 1)
    #expect(
      diagnosis.problems[0].hasPrefix("The running app is at /Users/someone/dev/Atelier.app"))
    #expect(diagnosis.problems[0].contains("atelier restart"))
    #expect(!diagnosis.text.contains("Everything checks out."))
  }

  @Test func aMissingPermissionAndConfigurationProblemsAreEachAProblem() {
    let diagnosis = diagnosis(
      .running(
        report(
          hasAccessibility: false,
          problems: [AppReport.Problem(location: "theme", message: "must be a theme")])),
      installed: matching)
    #expect(diagnosis.problems.count == 2)
    #expect(diagnosis.problems[0].contains("Accessibility permission"))
    #expect(diagnosis.problems[1] == "Configuration: theme: must be a theme")
    #expect(diagnosis.text.contains("Accessibility  missing"))
    #expect(diagnosis.text.contains("Configuration  1 in effect"))
  }

  @Test func aLoginItemAwaitingApprovalIsAProblemAndOneTheUserRemovedIsNot() {
    let waiting = diagnosis(
      .running(report(login: "requiresApproval", needsAttention: true)), installed: matching)
    #expect(waiting.problems == ["Login summary. Login advice."])
    let removed = diagnosis(.running(report(login: "notRegistered")), installed: matching)
    #expect(removed.problems.isEmpty)
    #expect(removed.text.contains("Open at login  Login summary."))
  }

  @Test func makeSortsWhatTheSocketSaysIntoTheThreeStates() throws {
    let json = String(decoding: try JSONEncoder().encode(report()), as: UTF8.self)
    let cases: [(Result<Reply, SocketError>, Diagnosis.App)] = [
      (.success(Reply(ok: true, output: json)), .running(report())),
      (.success(Reply(ok: false, output: "No such request.")), .unreachable("No such request.")),
      (.success(Reply(ok: true, output: "not json")), .unreachable("not json")),
      (.failure(.notRunning), .notRunning),
      (.failure(.badReply), .unreachable(SocketError.badReply.description)),
    ]
    for (answer, expected) in cases {
      let diagnosis = Diagnosis.make(commandPath: "/nowhere/atelier") { _ throws(SocketError) in
        try answer.get()
      }
      #expect(diagnosis.app == expected)
    }
  }

  @Test func theInstalledAppIsTheOneTheCommandCameIn() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "atelier-doctor-\(UUID().uuidString.prefix(8))")
    let app = folder.appending(path: "Atelier.app")
    let helpers = app.appending(path: "Contents/Helpers")
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"],
      format: .xml, options: 0
    ).write(to: app.appending(path: "Contents/Info.plist"))
    try Data().write(to: helpers.appending(path: "atelier"))
    // As Homebrew links it: a symlink elsewhere to the command inside the app.
    let link = folder.appending(path: "atelier")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: helpers.appending(path: "atelier"))
    let found = try #require(InstalledApp.find(commandPath: link.path))
    #expect(found.version == "1.2.3")
    #expect(found.build == "45")
    #expect(found.path.hasSuffix("/Atelier.app"))
    #expect(found.isAt(link.deletingLastPathComponent().appending(path: "Atelier.app").path))
    #expect(InstalledApp.read(folder) == nil)
    // The Hammerspoon version's app has the name, the identifier, and the
    // place, and not the command inside: it is not this Atelier.
    try FileManager.default.removeItem(at: helpers.appending(path: "atelier"))
    #expect(InstalledApp.read(app) == nil)
  }
}
