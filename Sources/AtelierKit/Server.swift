import Client
import Foundation

/// Listens on Atelier's socket and answers each connection's one request, for
/// as long as the app runs. Holding the lock beside the socket is what makes
/// this the one running Atelier; a second app finds it taken and must not
/// start. macOS releases the lock when the process ends, however it ends.
public enum Server {
  public enum StartError: Error, Equatable {
    case alreadyRunning
    case failed(String)
  }

  private static let queue = DispatchQueue(
    label: "com.elevenideas.Atelier.server", attributes: .concurrent)

  package static func start(
    path: String = Socket.defaultPath,
    answer: @escaping @Sendable (Request) async -> Reply
  ) throws(StartError) {
    do {
      try FileManager.default.createDirectory(
        at: URL(filePath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      throw .failed("Could not create the socket's folder: \(error.localizedDescription)")
    }
    let lock = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw .failed(SocketError.system("open").description) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      close(lock)
      throw .alreadyRunning
    }
    // No timeouts on the listener: waiting for the next client is its job.
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    do throws(SocketError) {
      // Anything at the path is a leftover, since its owner would hold the lock.
      unlink(path)
      // The mode keeps the socket to this user, whatever folder it is in.
      guard listener >= 0 else { throw SocketError.system("socket") }
      guard try Socket.withAddress(path, { bind(listener, $0, $1) }) == 0 else {
        throw SocketError.system("bind")
      }
      guard chmod(path, 0o600) == 0 else { throw SocketError.system("chmod") }
      guard listen(listener, 16) == 0 else { throw SocketError.system("listen") }
    } catch {
      close(listener)
      close(lock)
      throw .failed(error.description)
    }
    Thread.detachNewThread {
      while true {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else {
          // Interruptions are routine; the pause keeps a lasting failure, such
          // as running out of descriptors, from spinning.
          usleep(100_000)
          continue
        }
        Socket.setTimeouts(connection)
        queue.async { serve(connection, answer) }
      }
    }
  }

  private static func serve(
    _ connection: Int32, _ answer: @escaping @Sendable (Request) async -> Reply
  ) {
    guard let message = Socket.readMessage(connection),
      let request = try? JSONDecoder().decode(Request.self, from: message)
    else {
      close(connection)
      return
    }
    Task {
      let reply = await answer(request)
      queue.async {
        if let message = try? JSONEncoder().encode(reply) {
          _ = Socket.writeMessage(message, to: connection)
        }
        close(connection)
      }
    }
  }
}
