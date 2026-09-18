import Foundation
import ServiceManagement

/// What macOS says about opening this app at login.
package enum LoginItemStatus: Sendable, Equatable {
  case enabled
  /// Registered, and waiting for the user to allow it in Login Items.
  case requiresApproval
  /// Never registered, or removed by the user in Login Items; macOS does not
  /// tell the two apart.
  case notRegistered
  /// macOS cannot find this app to register it.
  case notFound
}

/// The app itself as a login item, which needs no helper app. macOS keeps the
/// registration, the user's approval, and the switch in Login Items.
enum LoginItem {
  static var status: LoginItemStatus {
    switch SMAppService.mainApp.status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notRegistered: .notRegistered
    case .notFound: .notFound
    @unknown default: .notFound
    }
  }

  static func register() -> String? {
    do {
      try SMAppService.mainApp.register()
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  static func openSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  /// True when the app runs from an Applications folder, as an installed copy
  /// does and a build in a source checkout does not.
  static var isInstalled: Bool {
    isInstalled(
      bundle: Bundle.main.bundleURL,
      applications: FileManager.default.urls(
        for: .applicationDirectory, in: [.localDomainMask, .userDomainMask]))
  }

  /// By the path the app was opened at: an entry in Applications that links
  /// elsewhere is installed all the same.
  static func isInstalled(bundle: URL, applications: [URL]) -> Bool {
    let bundle = bundle.standardizedFileURL.path
    return applications.contains { bundle.hasPrefix($0.standardizedFileURL.path + "/") }
  }
}
