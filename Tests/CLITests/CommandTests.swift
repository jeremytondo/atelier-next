import ArgumentParser
import Client
import Testing

@testable import CLI

@Suite struct CommandTests {
  private func request(_ words: [String]) throws -> Request? {
    (try AtelierCommand.parseAsRoot(words) as? any Asking)?.request
  }

  /// Every command and the request it stands for.
  private static let commands: [(words: [String], request: Request)] = [
    (["windows", "list"], Request(name: "windows.list")),
    (["windows", "list", "--json"], Request(name: "windows.list", json: true)),
    (["windows", "select", "2"], Request(name: "windows.select", arguments: ["2"])),
    (["windows", "cycle", "next"], Request(name: "windows.cycle", arguments: ["next"])),
    (["windows", "cycle", "previous"], Request(name: "windows.cycle", arguments: ["previous"])),
    (["windows", "move", "by", "1"], Request(name: "windows.move", arguments: ["by", "1"])),
    (["windows", "move", "by", "-2"], Request(name: "windows.move", arguments: ["by", "-2"])),
    (["windows", "move", "to", "3"], Request(name: "windows.move", arguments: ["to", "3"])),
    (["spaces", "list"], Request(name: "spaces.list")),
    (["spaces", "next"], Request(name: "spaces.next")),
    (["spaces", "previous"], Request(name: "spaces.previous")),
    (["spaces", "select", "4"], Request(name: "spaces.select", arguments: ["4"])),
    (["spaces", "move", "1", "3"], Request(name: "spaces.move", arguments: ["1", "3"])),
    (["desktops", "new"], Request(name: "desktops.new")),
    (["desktops", "new", "--json"], Request(name: "desktops.new", json: true)),
    (["desktops", "select", "1"], Request(name: "desktops.select", arguments: ["1"])),
    (["desktops", "delete"], Request(name: "desktops.delete")),
    (["spaces", "move", "by", "-1"], Request(name: "spaces.move", arguments: ["by", "-1"])),
    (
      ["spaces", "move", "by", "2", "--json"],
      Request(name: "spaces.move", arguments: ["by", "2"], json: true)
    ),
    (["windows", "arrange", "fill"], Request(name: "windows.arrange", arguments: ["fill"])),
    (
      ["windows", "arrange", "top-left", "--json"],
      Request(name: "windows.arrange", arguments: ["top-left"], json: true)
    ),
    (["config", "show"], Request(name: "config.show")),
    (["config", "show", "--json"], Request(name: "config.show", json: true)),
    (["config", "check"], Request(name: "config.check")),
    (["config", "open"], Request(name: "config.open")),
    (["config", "reload"], Request(name: "config.reload")),
  ]

  @Test(arguments: commands)
  func standsForOneRequest(words: [String], request: Request) throws {
    #expect(try self.request(words) == request)
  }

  @Test(arguments: [
    ["run", "desktops.new"], ["windows", "close"], ["windows", "select"],
    ["windows", "select", "two"], ["windows", "cycle", "sideways"], ["windows", "move", "3"],
    ["windows", "move", "by"], ["windows", "move", "by", "1", "2"], ["desktops", "move", "later"],
    ["spaces", "move", "1"], ["spaces", "move", "-f", "1", "-t", "2"],
    ["desktops", "new", "now"],
    ["spaces", "select", "1.5"], ["spaces", "move", "by"], ["spaces", "move", "by", "1", "2"],
    ["windows", "arrange"], ["windows", "arrange", "fill", "center"], ["config", "show", "now"],
    ["config", "reset"],
  ])
  func refusesWhatItDoesNotKnow(words: [String]) {
    #expect(throws: (any Error).self) { try AtelierCommand.parseAsRoot(words) }
  }
}
