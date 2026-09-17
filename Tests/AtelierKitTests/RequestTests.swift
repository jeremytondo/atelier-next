import AtelierKit
import Client
import Foundation
import Testing

@Suite struct RequestTests {
  private let mac = FakeMac(
    focusedWindow: 2, windows: [window(1, onScreen: false), window(2)])

  @Test func wordsTheWindowList() async {
    let reply = await Session(mac: mac).reply(to: Request(name: "windows.list"))
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
    let reply = await Session(mac: mac).reply(to: Request(name: "windows.list", json: true))
    let json = try JSONSerialization.jsonObject(with: Data(reply.output.utf8)) as? [String: Any]
    let windows = json?["windows"] as? [[String: Any]]
    #expect(reply.ok)
    #expect(json?["space"] as? String == "desktop")
    #expect(windows?.map { $0["id"] as? Int } == [2, 1])
    #expect(windows?.first?["focused"] as? Bool == true)
    #expect(windows?.last?["visible"] as? Bool == false)
  }

  @Test func saysWhenTheCurrentSpaceIsNotADesktop() async throws {
    let session = Session(mac: FakeMac(activeSpace: 4, shownOnSecondDisplay: 4))
    let text = await session.reply(to: Request(name: "windows.list"))
    #expect(text == Reply(ok: true, output: WindowList.notDesktopMessage))
    let reply = await session.reply(to: Request(name: "windows.list", json: true))
    let json = try JSONSerialization.jsonObject(with: Data(reply.output.utf8)) as? [String: Any]
    #expect(json?["space"] as? String == "notDesktop")
  }

  @Test func refusesWithoutAccessibility() async {
    let session = Session(mac: FakeMac(hasAccessibility: false))
    let reply = await session.reply(to: Request(name: "windows.list"))
    #expect(reply == Reply(ok: false, output: WindowListError.accessibilityRequired.message))
  }

  @Test func refusesUnknownRequests() async {
    let reply = await Session(mac: mac).reply(to: Request(name: "windows.close"))
    #expect(!reply.ok)
  }
}
