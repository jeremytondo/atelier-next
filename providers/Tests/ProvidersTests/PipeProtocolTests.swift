import Foundation
import Testing

@testable import Providers

private struct Echo: Decodable {
  let number: Int
}

private struct Reply: Encodable {
  let doubled: Int
}

private let commands: [String: PipeProtocol.Handler] = [
  "double": PipeProtocol.handler { (request: Echo) in Reply(doubled: request.number * 2) },
  "fail": PipeProtocol.handler { (_: NoArguments) in throw ProviderError("expected failure") },
]

private func respond(_ line: String) -> [String: Any] {
  let text = PipeProtocol.respond(to: line, using: commands)
  return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

@Test func typedHandlersAnswerUnderTheRequestID() {
  let response = respond(#"{"id":7,"command":"double","number":21}"#)
  #expect(response["id"] as? Int == 7)
  #expect(response["ok"] as? Bool == true)
  #expect((response["result"] as? [String: Any])?["doubled"] as? Int == 42)
  #expect(response["error"] == nil)
}

@Test func failuresKeepTheIDAndReportTheMessage() {
  let cases: [(String, String)] = [
    (#"{"id":1,"command":"fail"}"#, "expected failure"),
    (#"{"id":2,"command":"missing"}"#, "Unknown command: missing"),
    (#"{"id":3,"command":"double"}"#, "number required"),
    (#"{"id":4,"command":"double","number":"many"}"#, "Invalid number value"),
  ]
  for (line, message) in cases {
    let response = respond(line)
    #expect(response["ok"] as? Bool == false, Comment(rawValue: line))
    #expect(response["error"] as? String == message, Comment(rawValue: line))
    #expect(response["id"] is Int, Comment(rawValue: line))
    #expect(response["result"] == nil, Comment(rawValue: line))
  }
}

@Test func malformedAndOversizedLinesAreRefusedWithoutAnID() {
  let oversized =
    #"{"id":5,"command":"double","number":1,"pad":""#
    + String(
      repeating: "x", count: PipeProtocol.maximumRequestBytes) + "\"}"
  for line in ["not json", "[1,2]", #"{"id":6}"#, oversized] {
    let response = respond(line)
    #expect(response["ok"] as? Bool == false)
    #expect(response["error"] as? String == "Invalid JSON request")
    #expect(response["id"] == nil)
  }
}

@Test func responsesAreOneLineWithSortedKeys() {
  let text = PipeProtocol.respond(to: #"{"id":8,"command":"double","number":1}"#, using: commands)
  #expect(!text.contains("\n"))
  #expect(text == #"{"id":8,"ok":true,"result":{"doubled":2}}"#)
}
