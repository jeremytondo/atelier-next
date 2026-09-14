// A windowless AppKit process. No engine construction, hotkeys, configuration
// recovery, permission prompts, or Desktop mutations on the default probe path.
import AppKit
import NativeBridge
import Trial
import AtelierEngine

func commandOutput(_ path: String, _ arguments: [String]) -> String {
  let process = Process(), pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  process.standardOutput = pipe
  process.standardError = pipe
  do { try process.run() } catch { return error.localizedDescription }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// XcodeBuildMCP forwards SwiftPM's separator to the executable.
let arguments = Array(CommandLine.arguments.dropFirst()).drop(while: { $0 == "--" })
let args = Array(arguments)
let command = args.first ?? "probe"
let help = """
Usage:
  wmbridge-experiment [probe]
  wmbridge-experiment trace-probe
  wmbridge-experiment preflight DISPLAY-ID
  wmbridge-experiment create /absolute/new-run-directory DISPLAY-ID --disposable-session
  wmbridge-experiment reconcile /absolute/run-directory
  wmbridge-experiment diagnose /absolute/run-directory
  wmbridge-experiment cleanup /absolute/run-directory --disposable-session [--display RECONCILED-ID]
  wmbridge-experiment serve /absolute/private-state-directory --disposable-session
  wmbridge-experiment serve-script /absolute/private-state-directory requests.jsonl --disposable-session
Each run permits exactly one create attempt. Reconcile never replays a mutation.
Cleanup refuses active, occupied, uncertain, or non-owned Desktops; never retries dispatch.
"""
if command == "--help" { print(help); exit(0) }
guard (["probe", "trace-probe"].contains(command) && args.count <= 1) ||
  (command == "preflight" && args.count == 2) ||
  (command == "create" && args.count == 4 && args[3] == "--disposable-session") ||
  (command == "cleanup" && args.count == 3 && args[2] == "--disposable-session") ||
  (command == "cleanup" && args.count == 5 && args[2] == "--disposable-session" && args[3] == "--display") ||
  (command == "serve" && args.count == 3 && args[2] == "--disposable-session") ||
  (command == "serve-script" && args.count == 4 && args[3] == "--disposable-session") ||
  (["reconcile", "diagnose"].contains(command) && args.count == 2)
else { fputs(help + "\n", stderr); exit(64) }
setbuf(stdout, nil)
let appKitLoaded = NativeBridge.loadAppKit()
guard appKitLoaded else { fputs("NSApplicationLoad failed\n", stderr); exit(2) }
if command == "serve" || command == "serve-script" {
  MainActor.assumeIsolated {
    do {
      let state = try Journal(path: args[1], create: false)
      if command == "serve-script" {
        guard freopen(args[2], "r", stdin) != nil else { throw TrialError("Cannot open request script") }
      }
      try runAtelierEngine(stateDirectory: state.directory, commandExtension: { command, request in
        let timeout = DispatchWorkItem { _exit(124) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        func runPath() throws -> String {
          guard let path = request["runDirectory"] as? String,
            URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent() == state.directory
          else { throw TrialError("Each trial must be a direct child of the private state directory") }
          return path
        }
        switch command {
        case "wmbridgeProbe": return NativeBridge.probe() as? [String: Any]
        case "wmbridgeCreate":
          guard let display = request["display"] as? String else { throw TrialError("display required") }
          return try runCreate(path: runPath(), display: display, engineOwnsLock: true)
        case "wmbridgeReconcile": return try reconcile(path: runPath())
        case "wmbridgeCleanup": return try runCleanup(path: runPath(), engineOwnsLock: true, reconciledDisplay: request["display"] as? String)
        case "fixtureTyping":
          guard let id = request["spaceID"] as? String, let spaceID = UInt64(id) else { throw TrialError("spaceID required") }
          return try typingFixture(directory: state.directory, spaceID: spaceID)
        case "hello", "snapshot", "probe", "membership", "switch": return nil
        default: throw TrialError("Command excluded from the WMBridge experiment")
        }
      })
    } catch { fputs("Experiment host: \(error.localizedDescription)\n", stderr); exit(2) }
  }
  exit(0)
}
// The CLI timeout returns without terminating its child. Bound this owned
// process independently, even if a synchronous private dispatch blocks AppKit.
DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
  fputs("Native watchdog expired; inspect journal and reconcile. No replay.\n", stderr)
  _exit(124)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.async {
  if !["probe", "trace-probe"].contains(command) {
    do {
      let report: [String: Any]
      switch command {
      case "preflight": report = try runCreate(path: "", display: args[1], preflightOnly: true)
      case "create": report = try runCreate(path: args[1], display: args[2])
      case "cleanup": report = try runCleanup(path: args[1], reconciledDisplay: args.count == 5 ? args[4] : nil)
      case "diagnose": report = try diagnose(path: args[1])
      default: report = try reconcile(path: args[1])
      }
      let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      print(String(decoding: data, as: UTF8.self))
      exit(0)
    } catch {
      let report: [String: Any] = ["error": error.localizedDescription, "command": command,
        "instruction": "Inspect the run journal and reconcile; do not replay a mutation after an error."]
      let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      // XcodeBuildMCP's failure renderer preserves stderr, but can omit stdout.
      FileHandle.standardError.write(data + Data("\n".utf8)); exit(2)
    }
  }
  var report = (command == "trace-probe" ? NativeBridge.traceProbe() : NativeBridge.probe()) as! [String: Any]
  report["explicitNSApplicationLoad"] = appKitLoaded
  report["date"] = ISO8601DateFormatter().string(from: Date())
  report["os"] = commandOutput("/usr/bin/sw_vers", [])
  report["architecture"] = commandOutput("/usr/bin/uname", ["-m"])
  report["sip"] = commandOutput("/usr/bin/csrutil", ["status"])
  report["separateSpaces"] = NSScreen.screensHaveSeparateSpaces
  report["screens"] = NSScreen.screens.map { screen -> [String: Any] in
    ["name": screen.localizedName, "id": screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? NSNull(),
     "frame": NSStringFromRect(screen.frame), "scale": screen.backingScaleFactor]
  }
  report["accessibilityTrusted"] = AXIsProcessTrusted()
  let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
  report["guiSession"] = [
    "onConsole": session[kCGSessionOnConsoleKey as String] ?? NSNull(),
    "loginDone": session[kCGSessionLoginDoneKey as String] ?? NSNull(),
    "screenLocked": session["CGSSessionScreenIsLocked"] ?? NSNull(),
  ]
  report["host"] = "standalone AppKit event loop; not Atelier/HS2 host validation"
  report["observation"] = NativeBridge.observation()
  let pinURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Hammerspoon/upstream.json")
  report["hs2Pin"] = (try? Data(contentsOf: pinURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
  do {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  } catch { fputs("Report serialization failed: \(error)\n", stderr); exit(1) }
  exit(report["bridgeAnswered"] as? Bool == true ? 0 : 2)
}
app.run()
