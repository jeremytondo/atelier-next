// The process that hosts every provider: one dispatch table, the hello
// handshake, a single-instance lock, and a JSON-lines loop over stdin/stdout.
import AppKit
import ApplicationServices
import Darwin
import Foundation

@MainActor
final class ProvidersHost {
  private let spaces: SpacesProvider
  private let application = ApplicationProvider()

  /// Every command the binary answers. A provider contributes its own table
  /// under its name; the hello handshake belongs to the host.
  private lazy var commands: [String: PipeProtocol.Handler] = {
    var table: [String: PipeProtocol.Handler] = [
      "hello": PipeProtocol.handler { (_: NoArguments) in
        HelloResponse(protocolVersion: PipeProtocol.version, trusted: AXIsProcessTrusted())
      }
    ]
    for (name, handler) in spaces.commands { table["spaces.\(name)"] = handler }
    for (name, handler) in application.commands { table["application.\(name)"] = handler }
    return table
  }()

  init() throws {
    spaces = try SpacesProvider()
  }

  func handle(_ line: String) -> String {
    PipeProtocol.respond(to: line, using: commands)
  }

  func cleanup() {
    spaces.cleanup()
  }
}

/// Wraps a handler that moves windows or Spaces so it refuses without the
/// Accessibility grant Hammerspoon 2 passes on to this child process.
func requiringAccessibility<Request: Decodable>(
  _ body: @escaping (Request) throws -> any Encodable
) -> PipeProtocol.Handler {
  PipeProtocol.handler { (request: Request) in
    guard AXIsProcessTrusted() else {
      throw ProviderError("Accessibility permission required for Hammerspoon 2")
    }
    return try body(request)
  }
}

/// One providers process per user: a second instance would post duplicate
/// events and fight over temporary shortcut state. Hammerspoon 2 reload sends
/// the old instance SIGTERM without waiting for it, so the API retries launch
/// while the lock is still held; the distinct exit status tells it to.
final class SingleInstanceLock {
  static let heldExitStatus: Int32 = EX_TEMPFAIL
  private let descriptor: Int32

  init?() {
    let path = "/tmp/com.elevenideas.atelier.providers.\(getuid()).lock"
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0, Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
      if descriptor >= 0 { close(descriptor) }
      return nil
    }
    self.descriptor = descriptor
  }

  deinit {
    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
    close(descriptor)
  }
}

/// Serves JSON-lines requests from stdin on the main thread until stdin closes
/// or a termination signal arrives. An in-flight command finishes before the
/// signal is honored, and shortcut and pointer state are restored first.
@MainActor
public func runProviders() throws {
  setbuf(stdout, nil)
  guard let processLock = SingleInstanceLock() else {
    fputs("atelier-providers: another instance is still running.\n", stderr)
    exit(SingleInstanceLock.heldExitStatus)
  }
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let host = try ProvidersHost()
  signal(SIGTERM, SIG_IGN)
  signal(SIGINT, SIG_IGN)
  let signals = [SIGTERM, SIGINT].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
      host.cleanup()
      app.terminate(nil)
    }
    source.resume()
    return source
  }
  DispatchQueue.global().async {
    while let line = readLine() {
      DispatchQueue.main.sync {
        MainActor.assumeIsolated { print(host.handle(line)) }
      }
    }
    DispatchQueue.main.async {
      host.cleanup()
      app.terminate(nil)
    }
  }
  withExtendedLifetime((host, processLock, signals)) { app.run() }
}
