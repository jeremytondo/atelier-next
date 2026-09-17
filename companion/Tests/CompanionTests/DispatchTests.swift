import Companion
import Foundation
import Testing

@Suite struct DispatchTests {
  @Test func theBodyIsTheVersionedEnvelope() {
    let body = String(decoding: DispatchRequest(action: "reload-config").body, as: UTF8.self)
    #expect(body == #"{"action":"reload-config","parameters":{},"version":1}"#)
    let preset = DispatchRequest(action: "preset", parameters: ["name": "Dev \"one\""])
    #expect(
      String(decoding: preset.body, as: UTF8.self)
        == #"{"action":"preset","parameters":{"name":"Dev \"one\""},"version":1}"#)
  }

  @Test func credentialsNameThePortAndTheSecretOfThisVersionOnly() {
    let written = Data(#"{"version":1,"port":47820,"secret":"abc123"}"#.utf8)
    let credentials = Credentials.parse(written)
    #expect(credentials == Credentials(port: 47820, secret: "abc123"))
    #expect(credentials?.url.absoluteString == "http://127.0.0.1:47820/dispatch")
    #expect(
      credentials?.headers == [
        "Authorization": "Bearer abc123", "Content-Type": "application/json",
      ]
    )
    #expect(Credentials.path.path.hasSuffix("/Library/Application Support/Atelier/companion.json"))
    #expect(Credentials.parse(Data()) == nil)
    #expect(Credentials.parse(Data(#"{"version":2,"port":47820,"secret":"abc123"}"#.utf8)) == nil)
    #expect(Credentials.parse(Data(#"{"version":1,"port":0,"secret":"abc123"}"#.utf8)) == nil)
    #expect(Credentials.parse(Data(#"{"version":1,"port":47820,"secret":""}"#.utf8)) == nil)
  }

  @Test func parseReadsRepliesOfThisVersionOnly() {
    #expect(
      DispatchResponse.parse(Data(#"{"version":1,"ok":true,"result":null}"#.utf8))
        == DispatchResponse(ok: true))
    #expect(
      DispatchResponse.parse(
        Data(#"{"version":1,"ok":false,"error":"Atelier is not running (Paused)"}"#.utf8))
        == DispatchResponse(ok: false, error: "Atelier is not running (Paused)"))
    #expect(DispatchResponse.parse(Data()) == nil)
    #expect(DispatchResponse.parse(Data("not json".utf8)) == nil)
    #expect(DispatchResponse.parse(Data(#"{"version":2,"ok":true}"#.utf8)) == nil)
  }
}
