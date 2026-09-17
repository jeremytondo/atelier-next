import Foundation

/// The Unix socket the running app listens on. Each connection carries one
/// request and one reply, both JSON; a side finishes its message by closing
/// its half of the connection.
public enum Socket {
  /// One fixed place, so there is never more than one Atelier to talk to.
  public static var defaultPath: String {
    URL.applicationSupportDirectory.appending(path: "Atelier/atelier.sock").path
  }

  /// Requests and replies are far smaller; a larger message is a mistake.
  static let messageLimit = 1 << 20

  /// Seconds either side waits on the other. A window list takes well under one.
  static let timeout = 5

  package static func open() throws(SocketError) -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SocketError.system("socket") }
    setTimeouts(descriptor)
    return descriptor
  }

  /// Bounds every wait on the other side, and turns a write to a closed
  /// connection into an error instead of a signal.
  package static func setTimeouts(_ descriptor: Int32) {
    var interval = timeval(tv_sec: timeout, tv_usec: 0)
    var on: Int32 = 1
    let size = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, size)
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, size)
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }

  /// Calls `connect` or `bind` with the address of `path`.
  package static func withAddress(
    _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
  ) throws(SocketError) -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { throw SocketError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }

  /// Reads until the other side closes its half; nil on error, timeout, or a
  /// message over the limit.
  package static func readMessage(_ descriptor: Int32) -> Data? {
    var message = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count == 0 { return message }
      if count < 0 && errno == EINTR { continue }
      guard count > 0, message.count + count <= messageLimit else { return nil }
      message.append(buffer, count: count)
    }
  }

  /// Writes the whole message, then closes this half of the connection.
  package static func writeMessage(_ message: Data, to descriptor: Int32) -> Bool {
    let complete = message.withUnsafeBytes { bytes in
      var sent = 0
      while sent < bytes.count {
        let count = write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return false }
        sent += count
      }
      return true
    }
    shutdown(descriptor, SHUT_WR)
    return complete
  }
}

public enum SocketError: Error, Equatable, CustomStringConvertible {
  case notRunning
  case pathTooLong(String)
  case failed(String)
  case badReply

  public var description: String {
    switch self {
    case .notRunning: "Atelier is not running. Open the Atelier app, then try again."
    case .pathTooLong(let path): "The socket path is too long for macOS: \(path)"
    case .failed(let message): message
    case .badReply: "Atelier did not send a complete reply."
    }
  }

  /// Names the failed call and reads `errno`, so make it right after the call.
  package static func system(_ call: String) -> SocketError {
    .failed("\(call) failed: \(String(cString: strerror(errno)))")
  }
}
