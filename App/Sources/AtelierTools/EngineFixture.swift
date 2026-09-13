import Foundation

// A disposable protocol peer for EngineClientTests; it never starts the real engine or app UI.
func runEngineFixture(arguments: [String]) throws {
  let gate = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
  while let line = readLine() {
    guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let id = request["id"], let command = request["command"] as? String
    else { throw CocoaError(.coderReadCorrupt) }

    switch command {
    case "exit": exit(3)
    case "hang":
      Thread.sleep(forTimeInterval: 60)
      continue
    case "invalid":
      FileHandle.standardOutput.write(Data("not-json\n".utf8))
      continue
    case "hello":
      if let gate {
        try Data().write(to: gate.appendingPathComponent("hello-received"))
        while !FileManager.default.fileExists(atPath: gate.appendingPathComponent("continue").path) {
          Thread.sleep(forTimeInterval: 0.005)
        }
      }
    default: break
    }

    let result: [String: Any] = command == "hello"
      ? ["protocolVersion": 1, "pid": ProcessInfo.processInfo.processIdentifier, "trusted": true]
      : [:]
    var payload = try JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": result])
    payload.append(0x0A)
    FileHandle.standardOutput.write(payload.prefix(8))
    Thread.sleep(forTimeInterval: 0.005)
    FileHandle.standardOutput.write(payload.dropFirst(8))
  }
}
