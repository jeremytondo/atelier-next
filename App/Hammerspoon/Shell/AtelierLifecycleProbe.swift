// Exercises the actual shell lifecycle against private configuration and a
// nonmutating helper. Run-loop waits model asynchronous JS/helper completion.
import AppKit
import JavaScriptCore

@MainActor
enum AtelierLifecycleProbe {
  static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() {
      throw NSError(
        domain: "Atelier.Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
  static func wait(_ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
      try require(Date() < deadline, "Lifecycle probe timed out")
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
  }
  static func residentKB() throws -> Int {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
    task.standardOutput = pipe
    try task.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    task.waitUntilExit()
    guard task.terminationStatus == 0,
      let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      throw CocoaError(.coderReadCorrupt)
    }
    return value
  }
  static func run() throws {
    let manager = ManagerManager.shared
    let engine = manager.engine
    let file = try AtelierHost.configurationURL()
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Never replace an existing config, even when a probe is invoked by hand.
    try require(
      !FileManager.default.fileExists(atPath: file.path),
      "Lifecycle probe requires an empty private configuration directory")
    AtelierHost.probeHelper = true
    func write(_ source: String) throws { try Data(source.utf8).write(to: file, options: .atomic) }
    try Data("module.exports = {value: 42};".utf8).write(
      to: directory.appendingPathComponent("relative.js"))
    let spoon = directory.appendingPathComponent("Spoons/Probe")
    try FileManager.default.createDirectory(at: spoon, withIntermediateDirectories: true)
    try Data(
      #"{"name":"Probe","author":"Atelier","version":"1","description":"Private test"}"#.utf8
    ).write(to: spoon.appendingPathComponent("spoon.json"))
    try Data("module.exports = {value: 17};".utf8).write(
      to: spoon.appendingPathComponent("init.js"))
    let signed = !CommandLine.arguments.contains("--self-test-no-xpc")
    let source =
      (signed ? "hs.ipc.start();\n" : "") + """
        globalThis.ticks = 0;
        globalThis.independent = hs.timer.doEvery(0.01, () => ticks++);
        globalThis.relativeValue = require('./relative.js').value;
        globalThis.spoonValue = hs.loadSpoon('Probe').value;
        hs.urlevent.bind('lifecycle-probe', () => { globalThis.urlDelivered = true; });
        atelier.start({spaces:false, groups:false, overlay:false, quickApps:[], bindings:{'reload-config':'none'}}).catch(console.error);
        """
    try write(
      "globalThis.partialTicks = 0; globalThis.partialTimer = hs.timer.doEvery(0.01, () => partialTicks++); throw new Error('expected isolated failure');"
    )
    manager.start()
    // Let callbacks run before another evaluation can clear a stale exception.
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    try require(
      engine.eval("partialTicks > 1") as? Bool == true,
      "Configuration error stopped an independent timer")
    try write(source + "\nthrow new Error('expected partial configuration failure');")
    try? manager.reload()
    try require(
      AtelierStatus.shared.configurationError.contains("expected partial"),
      "Configuration exception was not presented")
    try wait { (engine.eval("ticks > 1 && atelier.state === 'Running'") as? Bool) == true }
    try require(
      !AtelierStatus.shared.configurationError.isEmpty,
      "Async defaults status hid the configuration exception")
    try require(
      engine.eval("relativeValue === 42 && spoonValue === 17") as? Bool == true,
      "Relative module/Spoon loading failed")
    try require(
      engine.eval("require('util').inspect({answer:42}).includes('42')") as? Bool == true,
      "Upgraded Node built-in loading failed")
    URLEventDispatcher.shared.dispatch(URL(string: "atelier://lifecycle-probe")!)
    try require(engine.eval("urlDelivered === true") as? Bool == true, "URL dispatch failed")
    manager.pause()
    let ticks = engine.eval("ticks") as? Int ?? 0
    try wait { (engine.eval("ticks") as? Int ?? 0) > ticks }
    try require(
      engine.eval("atelier.state === 'Paused'") as? Bool == true, "Pause did not stop defaults")
    manager.resume()
    try wait { engine.eval("atelier.state === 'Running'") as? Bool == true }
    // Native service failures cannot tear down working scripts.
    AtelierHost.presentError(
      CocoaError(.fileWriteNoPermission), action: "Expected diagnostics failure")
    try require(engine.hasContext(), "Native UI error destroyed scripts")
    try require(AtelierHost.diagnostics()["runtime"] != nil, "Runtime diagnostics missing")
    // Simulate a retiring process that has not exited. Reload must leave its
    // context reachable and refuse to start a replacement helper.
    engine.eval(
      "globalThis.realHelperRunning = atelier.helperRunning; atelier.helperRunning = () => true;")
    do {
      try manager.reload()
      throw CocoaError(.validationMissingMandatoryProperty)
    } catch {
      try require(
        AtelierStatus.shared.configurationError.contains("still stopping"),
        "Unsafe helper teardown was allowed")
    }
    try require(engine.hasContext(), "Unsafe teardown lost the retiring context")
    engine.eval("atelier.helperRunning = realHelperRunning;")
    try write(source)
    try manager.reload()
    try wait { engine.eval("atelier.state === 'Running'") as? Bool == true }
    try require(AtelierStatus.shared.configurationError.isEmpty, "Reload did not recover")
    if signed {
      try require(engine.eval("hs.ipc.isListening") as? Bool == true, "IPC did not start")
      let cli = directory.appendingPathComponent("hs2")
      try FileManager.default.createSymbolicLink(
        at: cli,
        withDestinationURL: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/hs2"))
      let process = Process()
      let input = Pipe()
      let output = Pipe()
      process.executableURL = cli
      process.arguments = ["--no-prompt", "--log-level", "javascript"]
      process.standardInput = input
      process.standardOutput = output
      process.standardError = output
      try process.run()
      defer { if process.isRunning { process.terminate() } }
      input.fileHandleForWriting.write(
        Data(
          "40 + 2\nthrow new Error('expected CLI error')\n'recovered after error'\nconsole.log('expected streamed log')\n"
            .utf8))
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
      try input.fileHandleForWriting.close()
      try wait { !process.isRunning }
      let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      try require(
        process.terminationStatus == 0 && text.contains("42") && text.contains("expected CLI error")
          && text.contains("recovered after error") && text.contains("expected streamed log"),
        "Bundled/symlinked CLI IPC failed: \(text)")
      // Authenticate in both directions. The platform nc binary does not
      // carry Atelier's signing team and must not evaluate a request.
      do {
        let untrusted = try HSIPCSocketConnection(
          serviceName: HSIPCServer.serviceName,
          requirement: "anchor apple generic and certificate leaf[subject.OU] = \"INVALIDTEAM\"")
        untrusted.invalidate()
        try require(false, "CLI accepted a server from the wrong signing team")
      } catch {
        try require((error as NSError).domain == "HSIPC", "Peer rejection check failed: \(error)")
      }
      let foreign = Process()
      let foreignInput = Pipe()
      let foreignOutput = Pipe()
      foreign.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
      foreign.arguments = ["-U", try HSIPCSocket.path(HSIPCServer.serviceName)]
      foreign.standardInput = foreignInput
      foreign.standardOutput = foreignOutput
      foreign.standardError = foreignOutput
      try foreign.run()
      defer { if foreign.isRunning { foreign.terminate() } }
      let request =
        #"{"kind":"evaluate","id":"foreign","code":"globalThis.foreignIPCPeerRan = true","result":"","isError":false,"level":0,"logLevel":""}"#
        + "\n"
      foreignInput.fileHandleForWriting.write(Data(request.utf8))
      try foreignInput.fileHandleForWriting.close()
      try wait { !foreign.isRunning }
      let rejected = String(
        decoding: foreignOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      try require(
        !rejected.contains("\"kind\":\"reply\"")
          && engine.eval("typeof foreignIPCPeerRan === 'undefined'") as? Bool == true,
        "IPC accepted an unsigned/differently signed client")
      for _ in 0..<5 {
        engine.eval("hs.ipc.stop(); hs.ipc.start();")
        try require(
          engine.eval("hs.ipc.isListening") as? Bool == true,
          "IPC stop/start did not release its socket")
      }
    }
    try write("globalThis.shouldNotRun = true; {{{ syntax !!!")
    try? manager.reload()
    try require(
      engine.eval("typeof shouldNotRun === 'undefined'") as? Bool == true,
      "Syntax error executed code")
    try require(!AtelierStatus.shared.configurationError.isEmpty, "Syntax error was not presented")
    try write(source)
    var samples: [[String: Int]] = []
    for index in 0...50 {
      try autoreleasepool {
        try manager.reload()
        try wait { engine.eval("atelier.state === 'Running' && ticks > 1") as? Bool == true }
        if signed {
          try require(engine.eval("hs.ipc.isListening") as? Bool == true, "Reload lost IPC")
        }
      }
      samples.append(["reload": index, "residentKB": try residentKB()])
    }
    // This route is used by custom scripts and the default reload hotkey.
    let previousID = JSEngine.shared.id
    engine.eval("hs.reload();")
    try wait {
      JSEngine.shared.id != previousID
        && engine.eval("typeof ticks !== 'undefined' && ticks > 1 && atelier.state === 'Running'")
          as? Bool == true
    }
    try require(manager.shutdown(), "Quit failed to clean up")
    try require(!engine.hasContext(), "Quit retained the context")
    try require(
      AtelierHost.diagnostics()["runtime"] == nil, "Native fallback diagnostics unavailable")
    let report: [String: Any] = [
      "version": AtelierHost.version, "reloads": 50, "samples": samples, "passed": true,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("lifecycle.json"), options: .atomic)
    print(
      "Packaged lifecycle probe passed (50 reloads); memory samples: \(directory.appendingPathComponent("lifecycle.json").path)"
    )
  }
}
