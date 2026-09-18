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
  public let login: Login
  public let config: Config
  public let quickApps: QuickApps
  public let leader: Leader
  public let notices: Notices
  let runner: CommandRunner

  /// `stateFolder` is where the window lists are kept between runs; without
  /// one they are not kept. `configFile` is the user's file; without one the
  /// defaults are all there is.
  package init(
    mac: any Mac, stateFolder: URL? = nil, configFile: URL? = nil, patience: Patience = Patience()
  ) {
    let workspace = Workspace(mac: mac, stateFolder: stateFolder, patience: patience)
    let store = ConfigStore(mac: mac, file: configFile)
    windows = Windows(workspace: workspace, config: store)
    spaces = Spaces(workspace: workspace)
    desktops = Desktops(workspace: workspace)
    permissions = Permissions(mac: mac)
    login = Login(mac: mac, stateFolder: stateFolder)
    config = Config(store: store, installation: Task { await store.start() })
    notices = Notices()
    quickApps = QuickApps(workspace: workspace, config: store)
    runner = CommandRunner(
      windows: windows, spaces: spaces, desktops: desktops, config: config, notices: notices,
      quickApps: quickApps)
    leader = Leader(
      session: LeaderSession(mac: mac, workspace: workspace, store: store, runner: runner))
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
  /// `ATELIER_CONFIG` in the environment names another file, for trying a
  /// configuration without touching one's own.
  public static func live() throws -> Atelier {
    let configFile =
      ProcessInfo.processInfo.environment["ATELIER_CONFIG"].map { URL(filePath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".config/atelier/\(configFileName)")
    let atelier = Atelier(
      mac: try LiveMac(),
      stateFolder: URL(filePath: Socket.defaultPath).deletingLastPathComponent(),
      configFile: configFile)
    try Server.start { await atelier.reply(to: $0) }
    // Only the one running Atelier has a first launch.
    atelier.login.begin()
    return atelier
  }

  /// A global shortcut was pressed: its command runs, or the leader opens,
  /// and a failure is a notice.
  private func pressed(_ chord: Chord) async {
    let current = await config.store.current
    do {
      if chord == current.leader.chord {
        _ = try await leader.open()
      } else if let command = current.global[chord] {
        _ = try await perform(command)
      }
    } catch {
      notices.post(error.message)
    }
  }
}
