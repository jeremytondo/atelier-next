import Client
import Foundation
import MacOS

/// Everything Atelier knows and does, with nothing visible. The app makes one
/// session; its interface and the `atelier` command both work through it.
public struct Session: Sendable {
  public let windows: Windows
  public let spaces: Spaces
  public let desktops: Desktops
  public let permissions: Permissions

  /// `stateFolder` is where the window lists are kept between runs; without
  /// one they are not kept.
  package init(mac: any Mac, stateFolder: URL? = nil, patience: Patience = Patience()) {
    let workspace = Workspace(mac: mac, stateFolder: stateFolder, patience: patience)
    windows = Windows(workspace: workspace)
    spaces = Spaces(workspace: workspace)
    desktops = Desktops(workspace: workspace)
    permissions = Permissions(mac: mac)
    Task { await workspace.watch() }
  }

  /// The session on the real Mac, answering the `atelier` command from now on.
  /// Throws `Server.StartError.alreadyRunning` when another Atelier has the job.
  public static func live() throws -> Session {
    let session = Session(
      mac: try LiveMac(),
      stateFolder: URL(filePath: Socket.defaultPath).deletingLastPathComponent())
    try Server.start { await session.reply(to: $0) }
    return session
  }
}
