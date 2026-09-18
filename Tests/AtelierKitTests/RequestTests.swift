import AtelierKit
import Client
import Foundation
import Testing

@Suite struct RequestTests {
  private let mac = FakeMac(
    focusedWindow: 2, windows: [window(1, onScreen: false), window(2)])

  private func reply(_ name: String, _ arguments: [String] = [], on mac: FakeMac) async -> Reply {
    await Atelier(mac).reply(to: Request(name: name, arguments: arguments))
  }

  @Test func wordsTheWindowList() async {
    let reply = await Atelier(mac).reply(to: Request(name: "windows.list"))
    #expect(
      reply
        == Reply(
          ok: true,
          output: """
            * 2  App 2 — Window 2
              1  App 1 — Window 1  (minimized or hidden)
            """))
  }

  @Test func answersInJSONWhenAsked() async throws {
    let reply = await Atelier(mac).reply(to: Request(name: "windows.list", json: true))
    let json = try JSONSerialization.jsonObject(with: Data(reply.output.utf8)) as? [String: Any]
    let windows = json?["windows"] as? [[String: Any]]
    #expect(reply.ok)
    #expect(json?["space"] as? String == "desktop")
    #expect(windows?.map { $0["id"] as? Int } == [2, 1])
    #expect(windows?.first?["focused"] as? Bool == true)
    #expect(windows?.last?["visible"] as? Bool == false)
  }

  @Test func saysWhenTheCurrentSpaceIsNotADesktop() async throws {
    let atelier = Atelier(FakeMac(activeSpace: 4, shownOnSecondDisplay: 4))
    let text = await atelier.reply(to: Request(name: "windows.list"))
    #expect(text == Reply(ok: true, output: WindowList.notDesktopMessage))
    let reply = await atelier.reply(to: Request(name: "windows.list", json: true))
    let json = try JSONSerialization.jsonObject(with: Data(reply.output.utf8)) as? [String: Any]
    #expect(json?["space"] as? String == "notDesktop")
  }

  @Test func refusesWithoutAccessibility() async {
    let atelier = Atelier(FakeMac(hasAccessibility: false))
    let reply = await atelier.reply(to: Request(name: "windows.list"))
    #expect(reply == Reply(ok: false, output: AtelierError.accessibilityRequired.message))
  }

  /// Each on a fresh Mac showing Desktop 2 of three, with window 1 focused.
  private static let commands: [(words: [String], requests: [String])] = [
    (["windows.select", "2"], ["raise 2"]), (["windows.cycle", "next"], ["raise 2"]),
    (["windows.cycle", "previous"], ["raise 3"]), (["spaces.next"], ["switch to 3"]),
    (["spaces.previous"], ["switch to 1"]), (["spaces.select", "3"], ["switch to 3"]),
    (["desktops.select", "1"], ["switch to 1"]), (["spaces.move", "1", "3"], ["move 1 to 2"]),
    (["spaces.move", "3", "1"], ["move 3 to 0"]),
    (["desktops.new"], ["create", "switch to 100"]),
    (["desktops.delete"], ["switch to 3", "destroy 2"]),
  ]

  @Test(arguments: commands)
  func runsCommandsByNameAndArguments(words: [String], requests: [String]) async {
    let mac = FakeMac.oneDisplay(
      current: 2, focusedWindow: 1,
      windows: [window(1, on: [2]), window(2, on: [2]), window(3, on: [2])])
    let reply = await reply(words[0], Array(words.dropFirst()), on: mac)
    #expect(reply == Reply(ok: true, output: "Done."))
    #expect(mac.requests == requests)
  }

  @Test func renumbersWindowsByNameAndArguments() async throws {
    let mac = FakeMac(focusedWindow: 1, windows: [window(1), window(2), window(3)])
    let atelier = Atelier(mac)
    #expect(await atelier.reply(to: Request(name: "windows.move", arguments: ["by", "1"])).ok)
    #expect(try await atelier.slots() == [2, 1, 3])
    #expect(await atelier.reply(to: Request(name: "windows.move", arguments: ["to", "3"])).ok)
    #expect(try await atelier.slots() == [2, 3, 1])
    let reply = await atelier.reply(to: Request(name: "windows.select", arguments: ["7"]))
    #expect(reply == Reply(ok: true, output: "Nothing to do."))
  }

  @Test func wordsTheSpaces() async {
    let mac = FakeMac.oneDisplay(notDesktops: [2], current: 3)
    #expect(
      await reply("spaces.list", on: mac).output == """
          1  Desktop 1  (1)
          2  Full screen or Split View  (2)
        * 3  Desktop 2  (3)
        """)
  }

  @Test func wordsAFailure() async {
    let mac = FakeMac.oneDisplay(spaces: 1...1)
    #expect(
      await reply("desktops.delete", on: mac)
        == Reply(ok: false, output: "The only Desktop cannot be deleted."))
  }

  @Test(arguments: [
    ["windows.close"], ["windows.select"], ["windows.select", "two"], ["windows.list", "1"],
    ["windows.cycle", "sideways"], ["windows.move", "3"], ["desktops.move"],
    ["desktops.new", "now"],
  ])
  func refusesWhatItDoesNotKnow(words: [String]) async {
    let reply = await Atelier(mac).reply(
      to: Request(name: words[0], arguments: Array(words.dropFirst())))
    #expect(!reply.ok)
    #expect(mac.requests.isEmpty)
  }
}
