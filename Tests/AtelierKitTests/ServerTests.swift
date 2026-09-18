import AtelierKit
import Client
import Foundation
import Testing

/// Each test gets its own socket in a private folder, so nothing here can
/// reach a running Atelier. A started server lives until the test process ends.
@Suite struct ServerTests {
  // Unix socket paths are short, so not the long per-user temporary folder.
  private let path = "/tmp/atelier-tests-\(UUID().uuidString.prefix(8))/atelier.sock"

  @Test func carriesARequestToTheAppAndItsReplyBack() async throws {
    try Server.start(path: path) { request in
      Reply(ok: request.json, output: "asked for \(request.name)")
    }
    let reply = try await Request(name: "windows.list", json: true).sent(to: path)
    #expect(reply == Reply(ok: true, output: "asked for windows.list"))
  }

  @Test func answersTheSameQueryAsTheInterface() async throws {
    let atelier = Atelier(FakeMac(windows: [window(1)]))
    try Server.start(path: path) { await atelier.reply(to: $0) }
    let reply = try await Request(name: "windows.list").sent(to: path)
    #expect(reply == Reply(ok: true, output: "  1  App 1 — Window 1"))
  }

  @Test func refusesToStartBesideARunningAtelier() throws {
    try Server.start(path: path) { _ in Reply(ok: true, output: "") }
    #expect(throws: Server.StartError.alreadyRunning) {
      try Server.start(path: path) { _ in Reply(ok: true, output: "") }
    }
  }

  @Test func keepsTheSocketPrivateToTheUser() throws {
    try Server.start(path: path) { _ in Reply(ok: true, output: "") }
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }

  @Test func saysWhenAtelierIsNotRunning() {
    #expect(throws: SocketError.notRunning) { try Request(name: "windows.list").send(to: path) }
  }

  @Test func saysWhenOnlyALeftoverSocketRemains() throws {
    try FileManager.default.createDirectory(
      atPath: URL(filePath: path).deletingLastPathComponent().path,
      withIntermediateDirectories: true)
    let leftover = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(leftover, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    close(leftover)
    #expect(bound == 0)
    #expect(throws: SocketError.notRunning) { try Request(name: "windows.list").send(to: path) }
  }
}
