import Client
import MacOS

/// Everything Atelier knows and does, with nothing visible. The app makes one
/// session; its interface and the `atelier` command both work through it.
public struct Session: Sendable {
  public let windows: Windows
  public let permissions: Permissions

  package init(mac: any Mac) {
    windows = Windows(mac: mac)
    permissions = Permissions(mac: mac)
  }

  /// The session on the real Mac, answering the `atelier` command from now on.
  /// Throws `Server.StartError.alreadyRunning` when another Atelier has the job.
  public static func live() throws -> Session {
    let session = Session(mac: try LiveMac())
    try Server.start { await session.reply(to: $0) }
    return session
  }
}
