import AppKit
import AtelierCore
import ServiceManagement

@MainActor
final class ConfigurationStore: ObservableObject {
  @Published private(set) var configuration = AppConfiguration()
  @Published private(set) var message: String?
  @Published private(set) var loadFailed = false
  @Published private(set) var loginStatus = ""
  @Published private(set) var files: [URL] = []
  let directory: URL
  let stateDirectory: URL
  let url: URL

  init(
    directory: URL = ConfigurationFiles.directory(), stateDirectory: URL? = nil,
    legacyQuickApps: URL? = nil, loginEnabled: Bool? = nil
  ) {
    self.directory = directory
    self.stateDirectory =
      stateDirectory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier", isDirectory: true)
    url = directory.appendingPathComponent("config.toml")
    do {
      try FileManager.default.createDirectory(
        at: self.stateDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      if !FileManager.default.fileExists(atPath: url.path) {
        var initial = AppConfiguration()
        let legacy = self.stateDirectory.appendingPathComponent("settings.json")
        let prototype =
          legacyQuickApps
          ?? FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".config/hammerspoon2/quickapps.js")
        if FileManager.default.fileExists(atPath: legacy.path) {
          initial = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: legacy))
          message = "Migrated settings.json. The original file is preserved and is no longer read."
        } else if FileManager.default.fileExists(atPath: prototype.path) {
          initial.quickApps = try QuickAppImporter.parse(
            String(contentsOf: prototype, encoding: .utf8))
          message =
            "Imported prototype Quick Apps. Hammerspoon files are preserved and are no longer read."
        }
        initial.launchAtLogin =
          loginEnabled
          ?? (SMAppService.mainApp.status == .enabled
            || SMAppService.mainApp.status == .requiresApproval)
        try initial.validate()
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        // Never replace an existing user's file, including one created while we migrate.
        try Data(ConfigurationFiles.starter(initial).utf8).write(
          to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
      let loaded = try read()
      configuration = loaded.configuration
      files = loaded.files
    } catch {
      loadFailed = true
      message = error.localizedDescription
    }
    updateLoginStatus()
  }

  func read() throws -> ConfigurationFiles.Loaded { try ConfigurationFiles.load(url) }

  /// Commit only after runtime validation/shortcut registration succeeds.
  func accept(_ loaded: ConfigurationFiles.Loaded) {
    configuration = loaded.configuration
    files = loaded.files
    loadFailed = false
    message = "Configuration reloaded."
  }
  func reject(_ error: Error) {
    message = "Configuration was not applied. \(error.localizedDescription)"
  }
  func applyLoginPreference() {
    guard let enabled = configuration.launchAtLogin else {
      updateLoginStatus()
      return
    }
    do {
      let status = SMAppService.mainApp.status
      if enabled && status != .enabled && status != .requiresApproval {
        try SMAppService.mainApp.register()
      } else if !enabled && (status == .enabled || status == .requiresApproval) {
        try SMAppService.mainApp.unregister()
      }
    } catch { message = "Configuration loaded. Launch at login: \(error.localizedDescription)" }
    updateLoginStatus()
  }
  func updateLoginStatus() {
    switch SMAppService.mainApp.status {
    case .enabled: loginStatus = "Enabled"
    case .requiresApproval: loginStatus = "Approval needed in System Settings → Login Items"
    case .notRegistered: loginStatus = "Off"
    case .notFound: loginStatus = "Install Atelier in Applications first"
    @unknown default: loginStatus = "Unavailable"
    }
  }
  func openConfiguration() {
    guard NSWorkspace.shared.open(url) else {
      NSWorkspace.shared.activateFileViewerSelecting([url])
      message = "Choose a text editor for config.toml in Finder’s Open With menu."
      return
    }
  }
  func openReference() {
    guard let url = Bundle.main.url(forResource: "Configuration", withExtension: "md") else {
      message = "The configuration reference is missing from this app bundle."
      return
    }
    NSWorkspace.shared.open(url)
  }
}
