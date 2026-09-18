import Foundation
import MacOS
import Synchronization

/// The `login` subject: whether Atelier opens at login. macOS Login Items owns
/// that. Atelier asks to be added once, on the installed app's first launch,
/// and never again on its own, so an item the user switched off or removed
/// stays that way through restarts, reloads, and updates. There is no setting
/// for it in the configuration.
///
/// Never asking twice comes first: the launch is put on record before macOS
/// is asked, so an app that died between the two has not asked and will not.
/// What is reported then is that Atelier does not open at login, and
/// `register` is there for whoever chooses to add it.
public final class Login: Sendable {
  private struct State {
    var isFirstLaunch = false
    var failure: String?
  }

  private let mac: any Mac
  /// Written on the first launch; nil when nothing is kept between runs.
  private let marker: URL?
  private let state = Mutex(State())

  init(mac: any Mac, stateFolder: URL?) {
    self.mac = mac
    marker = stateFolder?.appending(path: "first-launch")
  }

  /// False for a build run from a source checkout, which macOS should not
  /// open at login.
  public var isInstalled: Bool { mac.isInstalled }

  /// True when this run is the installed app's first launch, once `begin`
  /// has found it so. A build run from a source checkout never counts, and
  /// leaves the first launch to the installed app.
  public var isFirstLaunch: Bool { state.withLock(\.isFirstLaunch) }

  /// For the one running Atelier, once it is that: on the first launch, asks
  /// macOS to open Atelier at login. Creating the record is what decides that
  /// this launch is the first, so two apps can never both find it so.
  package func begin() {
    guard mac.isInstalled, let marker else { return }
    do {
      try FileManager.default.createDirectory(
        at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
      do {
        try Data().write(to: marker, options: .withoutOverwriting)
      } catch CocoaError.fileWriteFileExists {
        // An earlier launch was the first.
        return
      }
    } catch {
      state.withLock {
        $0.failure = "Atelier could not record its first launch: \(error.localizedDescription)"
      }
      return
    }
    state.withLock { $0.isFirstLaunch = true }
    register()
  }

  /// Asks macOS to open Atelier at login, for someone who chose to.
  public func register() {
    let refusal = mac.registerLoginItem()
    state.withLock {
      $0.failure = refusal.map { "macOS did not add Atelier to Login Items: \($0)" }
    }
  }

  public func openSettings() {
    mac.openLoginItemSettings()
  }

  /// What macOS says now. It sends no word of changes, so ask when it matters.
  public func status() -> LoginStatus {
    let status = mac.loginItemStatus
    // A failure is old news once macOS has the item after all.
    if status == .enabled || status == .requiresApproval { state.withLock { $0.failure = nil } }
    return LoginStatus(status, failure: state.withLock(\.failure))
  }
}

public struct LoginStatus: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case enabled, requiresApproval, notRegistered, notFound
  }

  public let kind: Kind
  /// Why the last request to macOS came to nothing, if it did.
  public let failure: String?

  init(_ status: LoginItemStatus, failure: String?) {
    kind =
      switch status {
      case .enabled: .enabled
      case .requiresApproval: .requiresApproval
      case .notRegistered: .notRegistered
      case .notFound: .notFound
      }
    self.failure = failure
  }

  /// True when something stands between Atelier and what was asked of macOS.
  /// An item the user removed is their choice, and not a problem.
  public var needsAttention: Bool {
    kind == .requiresApproval || kind == .notFound || failure != nil
  }

  public var summary: String {
    switch kind {
    case .enabled: "Atelier opens at login."
    case .requiresApproval: "Atelier opens at login once you allow it in Login Items."
    case .notRegistered: failure ?? "Atelier does not open at login."
    case .notFound: failure ?? "macOS cannot find Atelier to open it at login."
    }
  }

  /// What to do about it; nil when there is nothing to do.
  public var advice: String? {
    switch kind {
    case .enabled: nil
    case .requiresApproval:
      "Allow Atelier under Login Items & Extensions in System Settings."
    case .notRegistered:
      // After a refusal the summary is the refusal, which "that" would not fit.
      (failure == nil ? "To change that, add" : "You can add")
        + " Atelier to Open at Login under Login Items & Extensions in System Settings."
    case .notFound: "Open Atelier from the Applications folder, then look again."
    }
  }
}
