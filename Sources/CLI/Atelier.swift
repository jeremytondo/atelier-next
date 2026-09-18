import ArgumentParser
import Client
import Foundation

/// The `atelier` command. It knows how to reach the running app and nothing
/// about what the app does: each subcommand is one AtelierKit request, worded
/// for the terminal, and the app does the work and words the reply.
@main
struct AtelierCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "atelier",
    abstract: "Talk to the running Atelier app.",
    subcommands: [Windows.self, Spaces.self, Desktops.self])
}

/// A subcommand that stands for one request.
protocol Asking: ParsableCommand {
  var request: Request { get }
}

extension Asking {
  func run() throws {
    do {
      let reply = try request.send()
      guard reply.ok else { throw Failure(message: reply.output) }
      print(reply.output)
    } catch let error as SocketError {
      throw Failure(message: error.description)
    }
  }
}

struct Windows: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The current Desktop's numbered windows.",
    subcommands: [List.self, Select.self, Cycle.self, Move.self])

  struct List: Asking {
    static let configuration = CommandConfiguration(
      abstract: "List the windows in slot order, marking the focused one.")

    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "windows.list", json: json) }
  }

  struct Select: Asking {
    static let configuration = CommandConfiguration(abstract: "Focus the window in a slot.")

    @Argument(help: "The slot number, counting from 1.") var slot: Int
    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "windows.select", arguments: ["\(slot)"], json: json) }
  }

  struct Cycle: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Focus the next or previous window, wrapping around.")

    @Argument var direction: Direction
    @Flag(help: "Print JSON.") var json = false

    var request: Request {
      Request(name: "windows.cycle", arguments: [direction.rawValue], json: json)
    }
  }

  struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Renumber the focused window.", subcommands: [By.self, To.self])

    struct By: Asking {
      static let configuration = CommandConfiguration(
        abstract: "Move the focused window some slots later, or earlier when negative.",
        usage: "atelier windows move by <offset> [--json]")

      // Taken as words, so that a negative number is not read as an option.
      @Argument(
        parsing: .allUnrecognized,
        help: ArgumentHelp("How many slots, such as 1 or -1.", valueName: "offset"))
      var words: [String] = []
      @Flag(help: "Print JSON.") var json = false

      func validate() throws {
        guard words.count == 1, Int(words[0]) != nil else {
          throw ValidationError("Give one number of slots, such as 1 or -1.")
        }
      }

      var request: Request {
        Request(name: "windows.move", arguments: ["by", words[0]], json: json)
      }
    }

    struct To: Asking {
      static let configuration = CommandConfiguration(
        abstract: "Move the focused window to a slot.")

      @Argument(help: "The slot number, counting from 1.") var slot: Int
      @Flag(help: "Print JSON.") var json = false

      var request: Request {
        Request(name: "windows.move", arguments: ["to", "\(slot)"], json: json)
      }
    }
  }
}

struct Spaces: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The Spaces of the current display: Desktops, full screen, and Split View.",
    subcommands: [List.self, Next.self, Previous.self, Select.self, Move.self])

  struct List: Asking {
    static let configuration = CommandConfiguration(
      abstract: "List the Spaces in Mission Control order, marking the current one.")

    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "spaces.list", json: json) }
  }

  struct Next: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Go to the next Space, wrapping around.")

    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "spaces.next", json: json) }
  }

  struct Previous: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Go to the previous Space, wrapping around.")

    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "spaces.previous", json: json) }
  }

  struct Select: Asking {
    static let configuration = CommandConfiguration(abstract: "Go to a Space by its position.")

    @Argument(help: "The position in Mission Control order, counting from 1.") var position: Int
    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "spaces.select", arguments: ["\(position)"], json: json) }
  }

  struct Move: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Move a Space to another position, as dragging it in Mission Control would.")

    @Argument(help: "The position of the Space to move, from `spaces list`.") var from: Int
    @Argument(help: "The position to move it to.") var to: Int
    @Flag(help: "Print JSON.") var json = false

    var request: Request {
      Request(name: "spaces.move", arguments: ["\(from)", "\(to)"], json: json)
    }
  }
}

struct Desktops: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Desktops, the Spaces that hold windows. Changing them needs macOS 27.",
    subcommands: [New.self, Select.self, Delete.self])

  struct New: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Create a Desktop after the last Space and go to it.")

    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "desktops.new", json: json) }
  }

  struct Select: Asking {
    static let configuration = CommandConfiguration(abstract: "Go to a Desktop by its number.")

    @Argument(help: "The Desktop number, counting from 1.") var number: Int
    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "desktops.select", arguments: ["\(number)"], json: json) }
  }

  struct Delete: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Delete the current Desktop. macOS moves its windows to the Desktop shown next.")

    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "desktops.delete", json: json) }
  }
}

enum Direction: String, ExpressibleByArgument, CaseIterable {
  case next, previous
}

private struct Failure: Error, CustomStringConvertible {
  var message: String
  var description: String { message }
}
