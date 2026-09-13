import AppKit
import AtelierCore

@MainActor
final class EngineClient {
  private var process: Process?
  private var retiring: Process?
  private var writer: FileHandle?
  private var reader: FileHandle?
  private var errorReader: FileHandle?
  private var buffer = Data()
  private var sequence = 0
  private var pending: [Int: (CheckedContinuation<Data, Error>, Task<Void, Never>)] = [:]
  private var epoch = UUID()
  private let executable: URL?
  private let arguments: [String]
  private let timeoutSeconds: Double
  private(set) var stderr = ""
  var onFailure: ((String) -> Void)?
  var record: ((String, Double) -> Void)?
  var pid: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
  init(executable: URL? = nil, arguments: [String] = [], timeoutSeconds: Double = 15) {
    self.executable = executable
    self.arguments = arguments
    self.timeoutSeconds = timeoutSeconds
  }

  func start() async throws {
    guard process == nil else { throw AppError("The engine is already running.") }
    let token = UUID()
    epoch = token
    if let retiring {
      for _ in 0..<40 {
        if !retiring.isRunning { break }
        try await Task.sleep(for: .milliseconds(100))
        guard epoch == token else { throw CancellationError() }
      }
      guard !retiring.isRunning else {
        throw AppError("The previous engine is still stopping. Try Resume again shortly.")
      }
      self.retiring = nil
    }
    guard process == nil else { throw AppError("The engine is already running.") }
    let url =
      executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/atelier-engine")
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      throw AppError("The bundled engine is missing. Reinstall Atelier.")
    }
    let child = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    stderr = ""
    child.executableURL = url
    child.arguments = arguments
    child.standardInput = input
    child.standardOutput = output
    child.standardError = errors
    writer = input.fileHandleForWriting
    reader = output.fileHandleForReading
    errorReader = errors.fileHandleForReading
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      Task { @MainActor in
        guard let self, self.epoch == token else { return }
        if !data.isEmpty { self.receive(data) }
      }
    }
    errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      Task { @MainActor in
        guard let self, self.epoch == token else { return }
        self.stderr = String((self.stderr + String(decoding: data, as: UTF8.self)).suffix(8_192))
      }
    }
    child.terminationHandler = { [weak self] child in
      Task { @MainActor in
        guard let self, self.epoch == token else { return }
        let detail = self.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fail(
          "The engine stopped (\(child.terminationStatus)). \(detail) Inspect the current Desktop before restarting; an interrupted action may have completed."
        )
      }
    }
    process = child
    do {
      try child.run()
      let hello: EngineHello = try await request(EngineRequest("hello"))
      guard hello.protocolVersion == 1 else {
        throw AppError("App and engine versions do not match. Reinstall Atelier.")
      }
      guard hello.trusted else {
        throw AppError(
          "Grant Accessibility access to Atelier in System Settings, then press Resume.")
      }
    } catch {
      if epoch == token { stop() }
      throw error
    }
  }

  func request<T: Decodable>(_ request: EngineRequest) async throws -> T {
    guard process?.isRunning == true, let writer else { throw AppError("The engine is stopped.") }
    sequence += 1
    var request = request
    request.id = sequence
    let id = sequence
    let token = epoch
    let started = ProcessInfo.processInfo.systemUptime
    let payload = try JSONEncoder().encode(request) + Data([10])
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      let deadline = Task { [weak self] in
        try? await Task.sleep(for: .seconds(self?.timeoutSeconds ?? 15))
        guard !Task.isCancelled, let self, self.epoch == token, self.pending[id] != nil else {
          return
        }
        self.fail(
          "The engine timed out during \(request.command). The result is unknown. Inspect the current Desktop before restarting."
        )
      }
      pending[id] = (continuation, deadline)
      do { try writer.write(contentsOf: payload) } catch {
        fail("Could not contact the engine: \(error.localizedDescription)")
      }
    }
    record?("engine:\(request.command)", (ProcessInfo.processInfo.systemUptime - started) * 1000)
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func receive(_ data: Data) {
    buffer.append(data)
    guard buffer.count <= 4_194_304 else {
      fail("The engine response exceeded its size limit.")
      return
    }
    while let newline = buffer.firstIndex(of: 10) {
      let line = buffer[..<newline]
      buffer.removeSubrange(...newline)
      do {
        guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any],
          let id = reply["id"] as? Int
        else { throw AppError("Malformed engine response.") }
        guard let (continuation, timeout) = pending.removeValue(forKey: id) else { continue }
        timeout.cancel()
        if reply["ok"] as? Bool == true {
          do {
            continuation.resume(
              returning: try JSONSerialization.data(withJSONObject: reply["result"] ?? [:]))
          } catch { continuation.resume(throwing: error) }
        } else {
          continuation.resume(
            throwing: AppError(reply["error"] as? String ?? "The engine rejected the operation."))
        }
      } catch {
        fail("Invalid engine response: \(error.localizedDescription)")
        return
      }
    }
  }
  private func fail(_ message: String) {
    stop()
    onFailure?(message)
  }
  func stop() {
    epoch = UUID()
    reader?.readabilityHandler = nil
    errorReader?.readabilityHandler = nil
    try? writer?.close()
    writer = nil
    try? reader?.close()
    reader = nil
    try? errorReader?.close()
    errorReader = nil
    let child = process
    process = nil
    if let child { retiring = child }
    child?.terminationHandler = nil
    if child?.isRunning == true { child?.terminate() }
    // Keep the process object alive until graceful cleanup finishes. Escalate
    // only our own child if it cannot exit after EOF + SIGTERM.
    if let child {
      Task.detached {
        for _ in 0..<30 {
          if !child.isRunning { return }
          try? await Task.sleep(for: .milliseconds(100))
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
      }
    }
    let requests = pending.values
    pending.removeAll()
    buffer.removeAll()
    for (continuation, timeout) in requests {
      timeout.cancel()
      continuation.resume(
        throwing: AppError("The engine stopped; any interrupted mutation has an unknown outcome."))
    }
  }
}
