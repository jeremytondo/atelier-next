import Companion
import Foundation
import Testing

/// A fake Mac: whether Hammerspoon 2 runs, what the session wrote, and what its port answers.
private final class FakeMac {
  var running = true
  var credentials: Credentials? = Credentials(port: 47820, secret: "s3cret")
  var reply = Data(#"{"version":1,"ok":true,"result":null}"#.utf8)
  var failure: Error?
  var posts: [(url: URL, headers: [String: String], body: Data)] = []

  var runtime: Runtime {
    Runtime(
      hammerspoon: { self.running },
      credentials: { self.credentials },
      post: { url, headers, body in
        self.posts.append((url, headers, body))
        if let failure = self.failure { throw failure }
        return self.reply
      })
  }
}

private let reload = DispatchRequest(action: "reload-config")

@Suite struct RuntimeTests {
  @Test func nothingIsSentWhenHammerspoonIsNotRunning() async {
    let mac = FakeMac()
    mac.running = false
    #expect(await mac.runtime.deliver(reload) == .notRunning)
    #expect(mac.posts.isEmpty)
  }

  @Test func nothingIsSentWithoutTheSessionsCredentials() async {
    let mac = FakeMac()
    mac.credentials = nil
    #expect(await mac.runtime.deliver(reload) == .unreachable)
    #expect(mac.posts.isEmpty)
  }

  @Test func theEnvelopeIsPostedOnceWithTheSecretToTheSessionPort() async {
    let mac = FakeMac()
    #expect(await mac.runtime.deliver(reload) == .delivered(DispatchResponse(ok: true)))
    #expect(mac.posts.count == 1)
    #expect(mac.posts[0].url.absoluteString == "http://127.0.0.1:47820/dispatch")
    #expect(mac.posts[0].headers["Authorization"] == "Bearer s3cret")
    #expect(mac.posts[0].headers["Content-Type"] == "application/json")
    #expect(mac.posts[0].body == reload.body)
  }

  @Test func aRefusalIsDeliveredAsIs() async {
    let mac = FakeMac()
    mac.reply = Data(#"{"version":1,"ok":false,"error":"Another command is still running"}"#.utf8)
    #expect(
      await mac.runtime.deliver(reload)
        == .delivered(DispatchResponse(ok: false, error: "Another command is still running")))
    #expect(mac.posts.count == 1)
  }

  @Test func aStoppedSessionIsUnreachableAndSilent() async {
    let mac = FakeMac()
    mac.failure = URLError(.cannotConnectToHost)
    #expect(await mac.runtime.deliver(reload) == .unreachable)
    #expect(mac.posts.count == 1)
  }

  @Test func aConnectionLostAfterSendingIsDeliveredAndNeverSentAgain() async {
    let mac = FakeMac()
    mac.failure = URLError(.networkConnectionLost)
    #expect(await mac.runtime.deliver(reload) == .delivered(nil))
    #expect(mac.posts.count == 1)
    mac.reply = Data()
    mac.failure = nil
    #expect(await mac.runtime.deliver(reload) == .delivered(nil))
    #expect(mac.posts.count == 2)
  }

  @Test func otherFailuresAreReportedOnce() async {
    let mac = FakeMac()
    mac.failure = URLError(.timedOut)
    if case .failed(let reason) = await mac.runtime.deliver(reload) {
      #expect(!reason.isEmpty)
    } else {
      Issue.record("a timeout did not fail")
    }
    #expect(mac.posts.count == 1)
  }
}
