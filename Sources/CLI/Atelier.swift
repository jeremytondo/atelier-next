import ArgumentParser
import Client
import Foundation

/// The `atelier` command. It knows how to reach the running app and nothing
/// about what the app does: it sends a request and prints the reply.
@main
struct Atelier: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "atelier",
    abstract: "Talk to the running Atelier app.",
    subcommands: [Windows.self])
}

struct Windows: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Windows on the current Desktop.", subcommands: [List.self])

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List the current Desktop's windows, focused window first.")

    @Flag(help: "Print JSON.") var json = false

    func run() throws {
      try send(Request(name: "windows.list", json: json))
    }
  }
}

private func send(_ request: Request) throws {
  do {
    let reply = try request.send()
    guard reply.ok else { throw Failure(message: reply.output) }
    print(reply.output)
  } catch let error as SocketError {
    throw Failure(message: error.description)
  }
}

private struct Failure: Error, CustomStringConvertible {
  var message: String
  var description: String { message }
}
