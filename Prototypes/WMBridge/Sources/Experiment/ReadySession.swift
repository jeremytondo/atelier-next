// An optional, short-lived windowless session amortizes build/AppKit startup.
// Requests use the same single-shot journals and mutation locks as the CLI.
import AppKit
import Darwin
import Trial

func runReadySession(path: String) throws {
  let journal = try Journal(path: path, create: false)
  try journal.write("starting.json", ["pid": getpid()])
  let startupWatchdog = DispatchWorkItem {
    try? journal.write("failed.json", ["pid": getpid(), "error": "Prepared helper startup timed out; no Desktop was created"])
    _exit(124)
  }
  DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: startupWatchdog)
  defer { startupWatchdog.cancel() }
  let socketPath = journal.directory.appendingPathComponent("control.sock").path
  var address = sockaddr_un()
  let bytes = Array(socketPath.utf8) + [0]
  guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw TrialError("Session socket path is too long") }
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
  let listener = socket(AF_UNIX, SOCK_STREAM, 0)
  guard listener >= 0 else { throw TrialError("Cannot allocate session socket") }
  defer { close(listener); unlink(socketPath) }
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 4) == 0,
    fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw TrialError("Cannot bind the private session socket") }
  signal(SIGPIPE, SIG_IGN)
  var busy = false, stopping = false, lastRequest = ProcessInfo.processInfo.systemUptime
  func stop() {
    try? journal.write("stopped.json", ["pid": getpid(), "date": ISO8601DateFormatter().string(from: Date())])
    unlink(socketPath)
    exit(0)
  }
  func respond(_ client: Int32, _ report: [String: Any]) {
    defer { close(client) }
    guard var data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
    data.append(10)
    data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let sent = send(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
        if sent < 0 && errno == EINTR { continue }
        if sent <= 0 { break }
        offset += sent
      }
    }
  }
  let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
  source.setEventHandler {
    let client = accept(listener, nil, nil)
    guard client >= 0 else { return }
    // Darwin inherits O_NONBLOCK from the listener. The background reader must
    // wait for the client's first bytes instead of interpreting EAGAIN as EOF.
    let flags = fcntl(client, F_GETFL)
    guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { close(client); return }
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    guard !busy && !stopping else { respond(client, ["error": "Desktop helper is busy; no request was dispatched"]); return }
    busy = true
    DispatchQueue.global().async {
      var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
      while data.count <= 16_384 && !data.contains(10) {
        let count = recv(client, &buffer, buffer.count, 0)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
      DispatchQueue.main.async {
        let watchdog = DispatchWorkItem { _exit(124) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel(); busy = false; lastRequest = ProcessInfo.processInfo.systemUptime; if stopping { stop() } }
        do {
          guard data.count <= 16_384, data.last == 10,
            let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let args = request["arguments"] as? [String], let command = args.first else { throw TrialError("Invalid session request") }
          if args == ["ping"] { respond(client, ["pid": getpid(), "protocolVersion": 1]); return }
          if args == ["stop"] { respond(client, ["stopped": true]); stopping = true; return }
          guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.elevenideas.Atelier").isEmpty else {
            throw TrialError("Quit Atelier before a disposable Desktop trial")
          }
          let report: [String: Any]
          if command == "create-ready", (4...6).contains(args.count), args[3] == "--disposable-session",
            args.dropFirst(4).allSatisfy({ ["--enter", "--test-typing"].contains($0) }),
            !args.contains("--test-typing") || args.contains("--enter") {
            report = try runReady(path: args[1], display: args[2] == "auto" ? nil : args[2], enter: args.contains("--enter"), testTyping: args.contains("--test-typing"))
          } else if command == "cleanup-ready", args.count == 3, args[2] == "--disposable-session" {
            report = try runReadyCleanup(path: args[1])
          } else { throw TrialError("Command is not supported by the prepared helper") }
          respond(client, report)
        } catch { respond(client, ["error": error.localizedDescription,
          "instruction": "Inspect the trial journal. No retry or fallback was requested."] ) }
      }
    }
  }
  let timer = DispatchSource.makeTimerSource(queue: .main)
  timer.schedule(deadline: .now() + 1, repeating: 1)
  timer.setEventHandler { if !busy && ProcessInfo.processInfo.systemUptime - lastRequest >= 600 { stop() } }
  let signals = [SIGINT, SIGTERM].map { value -> DispatchSourceSignal in
    signal(value, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
    source.setEventHandler { stopping = true; if !busy { stop() } }
    source.resume()
    return source
  }
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.elevenideas.Atelier").isEmpty else {
    throw TrialError("Quit Atelier before preparing a disposable Desktop session")
  }
  // Initialize and check the bridge now, while preparation is off the input path.
  _ = try runCreate(path: "", display: nil, preflightOnly: true)
  source.resume(); timer.resume()
  try journal.write("ready.json", ["pid": getpid(), "protocolVersion": 1, "idleSeconds": 600])
  startupWatchdog.cancel()
  withExtendedLifetime((source, timer, signals)) { app.run() }
}
