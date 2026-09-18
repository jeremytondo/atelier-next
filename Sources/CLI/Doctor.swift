import ArgumentParser
import Client
import Foundation

/// An Atelier.app on disk, as far as the command can tell from outside.
struct InstalledApp: Equatable, Codable {
  var path: String
  var version: String
  var build: String

  var description: String { "\(version) (\(build))" }

  /// The app this command came in, which is where Homebrew links it from, or
  /// else the one in an Applications folder. Nil when there is none.
  static func find(commandPath: String = Diagnosis.commandPath) -> InstalledApp? {
    let command = URL(filePath: commandPath).resolvingSymlinksInPath()
    // Atelier.app/Contents/Helpers/atelier
    let enclosing = command.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let candidates =
      (enclosing.pathExtension == "app" ? [enclosing] : [])
      + FileManager.default.urls(
        for: .applicationDirectory, in: [.localDomainMask, .userDomainMask]
      ).map { $0.appending(path: "Atelier.app") }
    return candidates.lazy.compactMap(read).first
  }

  /// Nil for anything that is not this Atelier. The command inside is what
  /// tells it from the app of the Hammerspoon version, which has the same
  /// name, the same identifier, and the same place in Applications.
  static func read(_ app: URL) -> InstalledApp? {
    guard
      FileManager.default.fileExists(atPath: app.appending(path: "Contents/Helpers/atelier").path),
      let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let version = plist["CFBundleShortVersionString"] as? String,
      let build = plist["CFBundleVersion"] as? String
    else { return nil }
    return InstalledApp(path: app.path, version: version, build: build)
  }

  /// True when `path` is this app, however either is reached.
  func isAt(_ path: String) -> Bool {
    URL(filePath: self.path).resolvingSymlinksInPath().path
      == URL(filePath: path).resolvingSymlinksInPath().path
  }
}

/// Everything `atelier doctor` found, and what it makes of it. It only looks:
/// nothing here repairs anything, launches anything, or changes anything.
struct Diagnosis: Equatable {
  enum App: Equatable {
    case running(AppReport)
    case notRunning
    /// Something is there and did not give a report; why, as far as is known.
    case unreachable(String)

    /// Asks whatever is at the socket for its report. `restart` asks the same
    /// way to tell when the app has gone and when it is back.
    static func ask(_ send: (Request) throws(SocketError) -> Reply) -> App {
      do {
        let reply = try send(Request(name: "doctor", json: true))
        guard reply.ok,
          let report = try? JSONDecoder().decode(AppReport.self, from: Data(reply.output.utf8))
        else { return .unreachable(reply.output) }
        return .running(report)
      } catch .notRunning {
        return .notRunning
      } catch {
        return .unreachable(error.description)
      }
    }
  }

  var commandPath: String
  var installed: InstalledApp?
  var app: App

  /// Where this command really is. Not its first argument, which is only the
  /// name it was run by when the shell found it on the PATH.
  static var commandPath: String {
    Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
  }

  /// Asks the running app, and reads the rest from disk.
  static func make(
    commandPath: String = Diagnosis.commandPath,
    send: (Request) throws(SocketError) -> Reply = { request throws(SocketError) in
      try request.send()
    }
  ) -> Diagnosis {
    Diagnosis(
      commandPath: commandPath, installed: InstalledApp.find(commandPath: commandPath),
      app: App.ask(send))
  }

  /// What is wrong, each with what to do about it. Empty when all is well.
  var problems: [String] {
    var problems: [String] = []
    if installed == nil {
      problems.append(
        "No Atelier.app was found in an Applications folder. Install it with Homebrew.")
    }
    if let installed, installed.version != Build.version || installed.build != Build.number {
      problems.append(
        "The installed app is build \(installed.description) and this command is \(Build.description). Reinstall Atelier so the two match, and check which atelier your shell finds."
      )
    }
    switch app {
    case .notRunning:
      problems.append(
        "Atelier is not running, so its checks could not be made. Open Atelier, then run atelier doctor again."
      )
    case .unreachable(let reason):
      problems.append(
        "Atelier seems to be running but did not give a report: \(reason) Quit and reopen Atelier, then run atelier doctor again."
      )
    case .running(let report):
      if report.version != Build.version || report.build != Build.number {
        problems.append(
          "The running app is build \(report.version) (\(report.build)) and this command is \(Build.description). Run atelier restart to run the installed build."
        )
      }
      // The same build from somewhere else is still not the installed app, as
      // with a build run from a source checkout.
      if let installed, !installed.isAt(report.path) {
        problems.append(
          "The running app is at \(report.path), not the installed \(installed.path). Run atelier restart to run the installed one."
        )
      }
      if !report.hasAccessibility {
        problems.append(
          "Atelier does not have the Accessibility permission. Open Setup from Atelier's menu-bar item and switch Atelier on in Accessibility settings."
        )
      }
      if report.login.needsAttention {
        problems.append(
          [report.login.summary, report.login.advice].compactMap(\.self).joined(separator: " "))
      }
      problems += report.configurationProblems.map {
        "Configuration: \($0.location): \($0.message)"
      }
    }
    return problems
  }

  var text: String {
    let unavailable = "not checked; only the running app can say"
    var rows: [(String, String)] = [
      ("Command", "\(Build.description)  \(commandPath)"),
      ("Installed app", installed.map { "\($0.description)  \($0.path)" } ?? "none found"),
    ]
    switch app {
    case .running(let report):
      rows += [
        ("Running app", "\(report.version) (\(report.build))  \(report.path)"),
        ("Accessibility", report.hasAccessibility ? "granted" : "missing"),
        ("Open at login", report.login.summary),
        (
          "Configuration",
          (report.configurationProblems.isEmpty
            ? "no problems" : "\(report.configurationProblems.count) in effect")
            + (report.configurationFile.map { "  \($0)" } ?? "")
        ),
      ]
    case .notRunning, .unreachable:
      rows += [
        ("Running app", app == .notRunning ? "not running" : "not answering"),
        ("Accessibility", unavailable), ("Open at login", unavailable),
        ("Configuration", unavailable),
      ]
    }
    let lines = rows.map { "\($0.0.padding(toLength: 15, withPad: " ", startingAt: 0))\($0.1)" }
    let verdict =
      problems.isEmpty
      ? ["", "Everything checks out."] : ["", "Problems:"] + problems.map { "  - \($0)" }
    return (lines + verdict).joined(separator: "\n")
  }

  var json: String {
    struct Payload: Encodable {
      struct Command: Encodable {
        var version: String
        var build: String
        var path: String
      }
      var command: Command
      var installed: InstalledApp?
      /// running, notRunning, or unreachable.
      var app: String
      /// Present only when the app is running; the rest could not be checked.
      var running: AppReport?
      var problems: [String]
    }
    let (state, report): (String, AppReport?) =
      switch app {
      case .running(let report): ("running", report)
      case .notRunning: ("notRunning", nil)
      case .unreachable: ("unreachable", nil)
      }
    return encoded(
      Payload(
        command: Payload.Command(version: Build.version, build: Build.number, path: commandPath),
        installed: installed, app: state, running: report, problems: problems))
  }
}

struct Doctor: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check the installation: builds, permission, open at login, and configuration.",
    discussion: """
      Reports the build of this command, of the installed app, and of the running app, and \
      what the running app says of its Accessibility permission, open-at-login state, and \
      configuration problems. When the app is not running those are reported as not checked. \
      Doctor only looks. It does not repair, launch, or change anything. It exits with 1 when \
      something is wrong.
      """)

  @Flag(help: "Print JSON.") var json = false

  func run() throws {
    let diagnosis = Diagnosis.make()
    print(json ? diagnosis.json : diagnosis.text)
    if !diagnosis.problems.isEmpty { throw ExitCode(1) }
  }
}
