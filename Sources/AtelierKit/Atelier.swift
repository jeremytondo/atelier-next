import Client
import Foundation
import MacOS

/// Everything Atelier knows and does, with nothing visible: the root the app
/// makes once, holding one subject per group of commands. Its interface and
/// the `atelier` command both work through it, so `atelier.windows.select(2)`
/// here is `atelier windows select 2` in the terminal, and a key bound to
/// `windows select 2` in the configuration.
public struct Atelier: Sendable {
  public let windows: Windows
  public let spaces: Spaces
  public let desktops: Desktops
  public let permissions: Permissions
  public let config: Config
  public let notices: Notices

  /// `stateFolder` is where the window lists are kept between runs; without
  /// one they are not kept. `configFile` is the user's file; without one the
  /// defaults are all there is.
  package init(
    mac: any Mac, stateFolder: URL? = nil, configFile: URL? = nil, patience: Patience = Patience()
  ) {
    let workspace = Workspace(mac: mac, stateFolder: stateFolder, patience: patience)
    windows = Windows(workspace: workspace)
    spaces = Spaces(workspace: workspace)
    desktops = Desktops(workspace: workspace)
    permissions = Permissions(mac: mac)
    let store = ConfigStore(mac: mac, file: configFile)
    config = Config(store: store, installation: Task { await store.start() })
    notices = Notices()
    Task { await workspace.watch() }
    let atelier = self
    Task {
      // Each press on its own, so one during a slow command is refused as
      // busy rather than run later against another Desktop.
      for await chord in mac.hotKeyPresses() { Task { await atelier.pressed(chord) } }
    }
  }

  /// For now `config-next.toml`, since `config.toml` may still hold a file in
  /// the format of an earlier draft; it becomes `config.toml` once that is
  /// dealt with.
  static let configFileName = "config-next.toml"

  /// Atelier on the real Mac, answering the `atelier` command from now on.
  /// Throws `Server.StartError.alreadyRunning` when another Atelier has the job.
  public static func live() throws -> Atelier {
    let atelier = Atelier(
      mac: try LiveMac(),
      stateFolder: URL(filePath: Socket.defaultPath).deletingLastPathComponent(),
      configFile: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".config/atelier/\(configFileName)"))
    try Server.start { await atelier.reply(to: $0) }
    return atelier
  }

  /// A global shortcut was pressed: its command runs, and a failure is a notice.
  private func pressed(_ chord: Chord) async {
    guard let command = await config.store.current.global[chord] else { return }
    do {
      _ = try await perform(command)
    } catch {
      notices.post(error.message)
    }
  }
}
