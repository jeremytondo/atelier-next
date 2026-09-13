import AtelierCore
import XCTest

@testable import Atelier

final class EngineClientTests: XCTestCase {
  @MainActor private func makeClient(arguments: [String] = [], timeoutSeconds: Double = 5) throws
    -> EngineClient
  {
    let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("atelier-tools")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw AppError("Missing native engine fixture at \(executable.path)")
    }
    return EngineClient(
      executable: executable, arguments: ["--engine-fixture"] + arguments,
      timeoutSeconds: timeoutSeconds)
  }

  @MainActor private func start(_ client: EngineClient) async throws {
    do { try await client.start() }
    catch {
      XCTFail("Native engine fixture failed to start: \(client.stderr)")
      throw error
    }
  }

  @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw AppError("Timed out waiting for fixture") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @MainActor func testFragmentedRepliesAndRestartReleaseTheOwnedProcess() async throws {
    let client = try makeClient()
    defer { client.stop() }
    try await start(client)
    let firstPID = try XCTUnwrap(client.pid)
    let _: EmptyResult = try await client.request(EngineRequest("snapshot"))
    client.stop()
    XCTAssertNil(client.pid)
    try await start(client)
    XCTAssertNotEqual(client.pid, firstPID)
    client.stop()
    try await waitUntil { kill(firstPID, 0) != 0 }
    XCTAssertNotEqual(kill(firstPID, 0), 0)
  }
  @MainActor func testTimeoutStopsEngineAndDoesNotReplayMutation() async throws {
    let client = try makeClient(timeoutSeconds: 1)
    defer { client.stop() }
    var failure: String?
    client.onFailure = { failure = $0 }
    try await start(client)
    do {
      let _: EmptyResult = try await client.request(EngineRequest("hang"))
      XCTFail("Expected timeout")
    } catch { XCTAssertTrue(error.localizedDescription.contains("unknown outcome")) }
    XCTAssertNil(client.pid)
    XCTAssertTrue(failure?.contains("result is unknown") == true)
  }
  @MainActor func testUnexpectedExitAndMalformedOutputFailPendingRequests() async throws {
    for command in ["exit", "invalid"] {
      let client = try makeClient()
      defer { client.stop() }
      try await start(client)
      do {
        let _: EmptyResult = try await client.request(EngineRequest(command))
        XCTFail("Expected engine failure")
      } catch { XCTAssertTrue(error.localizedDescription.contains("unknown outcome")) }
      XCTAssertNil(client.pid)
    }
  }
  @MainActor func testCancelledStartupCannotStopItsReplacementSession() async throws {
    let gate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: gate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: gate) }
    let client = try makeClient(arguments: [gate.path])
    defer { client.stop() }
    let first = Task { try await client.start() }
    defer { first.cancel() }
    try await waitUntil {
      FileManager.default.fileExists(atPath: gate.appendingPathComponent("hello-received").path)
    }
    client.stop()
    try Data().write(to: gate.appendingPathComponent("continue"))
    try await start(client)
    _ = try? await first.value
    XCTAssertNotNil(client.pid)
    let _: EmptyResult = try await client.request(EngineRequest("snapshot"))
  }
}
