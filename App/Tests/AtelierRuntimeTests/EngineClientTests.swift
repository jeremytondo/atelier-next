import AtelierCore
import XCTest

@testable import Atelier

final class EngineClientTests: XCTestCase {
  private let source = #"""
    import json, os, sys, time
    for line in sys.stdin:
        r=json.loads(line)
        command=r['command']
        if command=='exit': sys.exit(3)
        if command=='hang': time.sleep(5); continue
        if command=='invalid': print('not-json',flush=True); continue
        result={'protocolVersion':1,'pid':os.getpid(),'trusted':True} if command=='hello' else {}
        payload=json.dumps({'id':r['id'],'ok':True,'result':result})+'\n'
        sys.stdout.write(payload[:8]); sys.stdout.flush()
        time.sleep(0.005)
        sys.stdout.write(payload[8:]); sys.stdout.flush()
    """#
  @MainActor func testFragmentedRepliesAndRestartReleaseTheOwnedProcess() async throws {
    let client = EngineClient(
      executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", source],
      timeoutSeconds: 1)
    try await client.start()
    let firstPID = try XCTUnwrap(client.pid)
    let _: EmptyResult = try await client.request(EngineRequest("snapshot"))
    client.stop()
    XCTAssertNil(client.pid)
    try await client.start()
    XCTAssertNotEqual(client.pid, firstPID)
    client.stop()
    for _ in 0..<40 {
      if kill(firstPID, 0) != 0 { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotEqual(kill(firstPID, 0), 0)
  }
  @MainActor func testTimeoutStopsEngineAndDoesNotReplayMutation() async throws {
    let client = EngineClient(
      executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", source],
      timeoutSeconds: 0.25)
    var failure: String?
    client.onFailure = { failure = $0 }
    try await client.start()
    do {
      let _: EmptyResult = try await client.request(EngineRequest("hang"))
      XCTFail("Expected timeout")
    } catch { XCTAssertTrue(error.localizedDescription.contains("unknown outcome")) }
    XCTAssertNil(client.pid)
    XCTAssertTrue(failure?.contains("result is unknown") == true)
    client.stop()
  }
  @MainActor func testUnexpectedExitAndMalformedOutputFailPendingRequests() async throws {
    for command in ["exit", "invalid"] {
      let client = EngineClient(
        executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", source],
        timeoutSeconds: 1)
      try await client.start()
      do {
        let _: EmptyResult = try await client.request(EngineRequest(command))
        XCTFail("Expected engine failure")
      } catch { XCTAssertTrue(error.localizedDescription.contains("unknown outcome")) }
      XCTAssertNil(client.pid)
      client.stop()
    }
  }
  @MainActor func testCancelledStartupCannotStopItsReplacementSession() async throws {
    let slow = source.replacingOccurrences(
      of: "command=r['command']",
      with: "command=r['command']\n    if command=='hello': time.sleep(.2)")
    let client = EngineClient(
      executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", slow],
      timeoutSeconds: 2)
    let first = Task { try await client.start() }
    try await Task.sleep(for: .milliseconds(50))
    client.stop()
    try await client.start()
    _ = try? await first.value
    XCTAssertNotNil(client.pid)
    let _: EmptyResult = try await client.request(EngineRequest("snapshot"))
    client.stop()
  }
}
