import Client
import Foundation
import MacOS

/// Everything Atelier knows and does, with nothing visible: the root the app
/// makes once, holding one subject per group of commands. Its interface and
/// the `atelier` command both work through it, so `atelier.windows.select(2)`
/// here is `atelier windows select 2` in the terminal.
public struct Atelier: Sendable {
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

  /// Atelier on the real Mac, answering the `atelier` command from now on.
  /// Throws `Server.StartError.alreadyRunning` when another Atelier has the job.
  public static func live() throws -> Atelier {
    let atelier = Atelier(
      mac: try LiveMac(),
      stateFolder: URL(filePath: Socket.defaultPath).deletingLastPathComponent())
    try Server.start { await atelier.reply(to: $0) }
    return atelier
  }
}
