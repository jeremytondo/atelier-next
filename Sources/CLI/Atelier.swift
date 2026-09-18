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
    subcommands: [Windows.self, Spaces.self, Desktops.self, Config.self])
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
    subcommands: [List.self, Select.self, Cycle.self, Move.self, Arrange.self])

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

  struct Arrange: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Arrange the focused window with one of macOS's own Window menu actions.",
      discussion: """
        macOS chooses the windows and the layout, as choosing the item in the Window menu \
        would. The arrangements are fill, center, left, right, top, bottom, top-left, \
        top-right, bottom-left, bottom-right, left-right, right-left, top-bottom, \
        bottom-top, left-quarters, right-quarters, top-quarters, bottom-quarters, and quarters.
        """)

    @Argument(help: "The arrangement, such as fill or top-left.") var arrangement: String
    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "windows.arrange", arguments: [arrangement], json: json) }
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
      abstract: "Move a Space: one by position, or the current one by some positions.",
      usage: """
        atelier spaces move <from> <to> [--json]
        atelier spaces move by <offset> [--json]
        """,
      discussion: """
        With two positions, the Space at the first moves to the second, as dragging it \
        in Mission Control would. With `by`, the current Space moves that many positions \
        later, or earlier when negative, and stays where it is at either end.
        """)

    // Taken as words, so that a negative number is not read as an option.
    @Argument(
      parsing: .allUnrecognized,
      help: ArgumentHelp("Two positions, or `by` and an offset such as 1 or -1.", valueName: "move")
    )
    var words: [String] = []
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
      let byOffset = words.count == 2 && words[0] == "by" && Int(words[1]) != nil
      let positions = words.count == 2 && Int(words[0]) != nil && Int(words[1]) != nil
      guard byOffset || positions else {
        throw ValidationError(
          "Give two positions, such as 1 3, or `by` and an offset, such as by -1.")
      }
    }

    var request: Request { Request(name: "spaces.move", arguments: words, json: json) }
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

struct Config: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The configuration file, ~/.config/atelier/config-next.toml, and what is in effect.",
    subcommands: [Show.self, Check.self, Open.self, Reload.self])

  struct Show: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Print the configuration in effect: keys, leader menu, Quick Apps, and problems.")

    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "config.show", json: json) }
  }

  struct Check: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Read the file and report its problems without applying it.")

    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "config.check", json: json) }
  }

  struct Open: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Open the file in its app, writing a commented starting point if there is none.")

    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "config.open", json: json) }
  }

  struct Reload: Asking {
    static let configuration = CommandConfiguration(
      abstract: "Read the file and put it into effect. Atelier never reloads on its own.")

    @Flag(help: "Print JSON.") var json = false

    var request: Request { Request(name: "config.reload", json: json) }
  }
}

enum Direction: String, ExpressibleByArgument, CaseIterable {
  case next, previous
}

private struct Failure: Error, CustomStringConvertible {
  var message: String
  var description: String { message }
}
