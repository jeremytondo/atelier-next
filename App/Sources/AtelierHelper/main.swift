import AtelierEngine
import Foundation

// The isolated bundle probe exercises real HS2 process I/O against this stub
// instead of the engine, so it never needs permissions or mutates macOS.
if Array(CommandLine.arguments.dropFirst()) == ["--self-test-helper"],
  ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"] != nil
{
  while let line = readLine() {
    guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let id = request["id"] as? Int
    else { exit(1) }
    let result: [String: Any] =
      request["command"] as? String == "hello"
      ? ["protocolVersion": 1, "trusted": true]
      : [
        "trusted": true, "displays": [], "windows": [], "focused": 0, "targetDisplay": "",
        "missionControl": false,
      ]
    let data = try JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": result])
    FileHandle.standardOutput.write(data + Data([10]))
  }
  exit(0)
}

MainActor.assumeIsolated {
  do {
    try runAtelierEngine()
  } catch {
    fputs("Atelier engine: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
  }
}
