import ArgumentParser
import Client
import Foundation

/// Quitting and restarting the app from outside it. `atelier restart` is for
/// an Atelier still running the build from before an update, which `atelier
/// doctor` points out: it comes back as the installed build, and an Atelier
/// that was closed stays closed. What these touch is handed in, so they can be
/// tried without an app.
struct Restarting {
  var send: (Request) throws(SocketError) -> Reply
  /// The installed app; nil when there is none.
  var installedApp: () -> InstalledApp?
  /// Opens the app at a path. False when macOS would not.
  var open: (String) -> Bool
  var pause: () -> Void = { usleep(100_000) }
  /// How many pauses each wait lasts: for a running command, for the app to
  /// go, and for it to come back.
  var patience = 100

  /// Asks the app to quit, asking again while it is only busy with a command,
  /// which is never cut short. False when no Atelier was running.
  func askToQuit() throws(Failure) -> Bool {
    var wasRunning = false
    for _ in 0..<patience {
      let reply: Reply
      do {
        reply = try send(Request(name: "quit"))
      } catch .notRunning {
        // Gone between two askings is gone all the same, and it was running.
        return wasRunning
      } catch {
        throw Failure(message: "Atelier could not be asked to quit: \(error.description)")
      }
      if reply.ok { return true }
      // Anything but busy will not change by asking again: an older Atelier
      // that does not know the request, for one.
      guard reply.busy == true else {
        throw Failure(message: "Atelier would not quit: \(reply.output)")
      }
      wasRunning = true
      pause()
    }
    throw Failure(message: "Atelier stayed busy and was not asked to quit. It is still running.")
  }

  /// What to tell the person. Throws when the app is left in doubt.
  func run() throws(Failure) -> String {
    let nothing = "Atelier is not running, so there is nothing to restart."
    // Looked for first: with no app to open, quitting would only take Atelier away.
    guard let app = installedApp() else {
      if Diagnosis.App.ask(send) == .notRunning { return nothing }
      throw Failure(
        message: "No installed Atelier.app was found to open again, so Atelier was left running.")
    }
    guard try askToQuit() else { return nothing }
    guard wait(until: { Diagnosis.App.ask(send) == .notRunning }) else {
      throw Failure(
        message: "Atelier was asked to quit and is still running. It was not reopened.")
    }
    guard open(app.path) else {
      throw Failure(
        message: "Atelier quit, but macOS would not open \(app.path). Open it yourself.")
    }
    var answer = Diagnosis.App.notRunning
    guard
      wait(until: {
        answer = Diagnosis.App.ask(send)
        if case .running = answer { return true }
        return false
      }), case .running(let report) = answer
    else {
      throw Failure(
        message: "Atelier quit and \(app.path) was opened, but it is not answering properly yet.")
    }
    // Another Atelier may have got in first; then the one opened gave way to it.
    guard report.version == app.version, report.build == app.build, app.isAt(report.path) else {
      throw Failure(
        message:
          "Atelier quit, but what is running now is build \(report.version) (\(report.build)) at \(report.path), not the installed \(app.description) at \(app.path)."
      )
    }
    return "Atelier restarted as build \(app.description)."
  }

  private func wait(until condition: () -> Bool) -> Bool {
    for _ in 0..<patience {
      if condition() { return true }
      pause()
    }
    return condition()
  }
}

extension Restarting {
  /// Against the real app and the real Mac.
  static var live: Restarting {
    Restarting(
      send: { request throws(SocketError) in try request.send() },
      installedApp: { InstalledApp.find() },
      open: { path in
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = [path]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
      })
  }
}

struct Quit: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Quit the running app, once any command in progress is done.")

  func run() throws {
    guard try Restarting.live.askToQuit() else {
      throw Failure(message: SocketError.notRunning.description)
    }
    print("Atelier is quitting.")
  }
}

struct Restart: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Quit the running app and open the installed one. Nothing when it is not running.",
    discussion: """
      For an Atelier still running the build from before an update, which atelier doctor \
      points out. It is called a restart only when what answers afterwards is the installed \
      build at the installed place.
      """)

  func run() throws {
    print(try Restarting.live.run())
  }
}
