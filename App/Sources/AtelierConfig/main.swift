import AtelierCore
import Foundation

// A private packaging probe exercises real HS2 process I/O without granting
// permissions or running the macOS mutation helper.
if CommandLine.arguments == [CommandLine.arguments[0], "--self-test-helper"],
  ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"] != nil {
  while let line = readLine() {
    guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let id = request["id"] as? Int else { exit(1) }
    let result: [String: Any] = request["command"] as? String == "hello"
      ? ["protocolVersion": 1, "trusted": true]
      : ["trusted": true, "displays": [], "windows": [], "focused": 0, "targetDisplay": "", "missionControl": false]
    let data = try JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": result])
    FileHandle.standardOutput.write(data + Data([10]))
  }
  exit(0)
}

do {
  guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--bootstrap" else {
    throw AppError("usage: atelier-config --bootstrap CONFIG_DIRECTORY")
  }
  let isolated = ProcessInfo.processInfo.environment["ATELIER_CONFIG_DIR"] != nil
  let home = FileManager.default.homeDirectoryForCurrentUser
  try JavaScriptConfiguration.bootstrap(
    directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
    legacy: isolated ? nil : home.appendingPathComponent("Library/Application Support/Atelier/settings.json"),
    prototype: isolated ? nil : home.appendingPathComponent(".config/hammerspoon2/quickapps.js"))
} catch {
  FileHandle.standardError.write(Data("Atelier configuration: \(error.localizedDescription)\n".utf8))
  exit(1)
}
