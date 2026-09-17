import Foundation

extension Request {
  /// Sends the request to the running app and waits for its reply.
  public func send(to path: String = Socket.defaultPath) throws(SocketError) -> Reply {
    let descriptor = try Socket.open()
    defer { close(descriptor) }
    guard try Socket.withAddress(path, { connect(descriptor, $0, $1) }) == 0 else {
      // No socket, or one left behind with nobody listening.
      throw [ENOENT, ECONNREFUSED].contains(errno) ? .notRunning : .system("connect")
    }
    guard let message = try? JSONEncoder().encode(self),
      Socket.writeMessage(message, to: descriptor),
      let data = Socket.readMessage(descriptor),
      let reply = try? JSONDecoder().decode(Reply.self, from: data)
    else { throw .badReply }
    return reply
  }
}
