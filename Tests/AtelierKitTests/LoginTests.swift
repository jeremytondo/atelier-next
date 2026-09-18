import Foundation
import MacOS
import Testing

@testable import AtelierKit

/// Opening at login: asked of macOS once, and macOS's from then on. Each test
/// has a private state folder.
@Suite struct LoginTests {
  private let folder = FileManager.default.temporaryDirectory.appending(
    path: "atelier-login-\(UUID().uuidString.prefix(8))")

  private func installedMac() -> FakeMac {
    let mac = FakeMac()
    mac.change { $0.isInstalled = true }
    return mac
  }

  /// One run of the app, from its start.
  private func launch(_ mac: FakeMac, stateFolder: URL?) -> Login {
    let login = Login(mac: mac, stateFolder: stateFolder)
    login.begin()
    return login
  }

  @Test func theFirstLaunchOfTheInstalledAppAsksMacOSOnce() {
    let mac = installedMac()
    let first = launch(mac, stateFolder: folder)
    #expect(first.isFirstLaunch)
    #expect(mac.requests == ["register login item"])
    #expect(first.status().kind == .enabled)
    #expect(!launch(mac, stateFolder: folder).isFirstLaunch)
    #expect(mac.requests == ["register login item"])
  }

  @Test func aLaunchThatDecidedEarlyStillYieldsToTheOneThatRecordedFirst() {
    // Both exist before either begins, as when one waits on the other's lock.
    let mac = installedMac()
    let one = Login(mac: mac, stateFolder: folder)
    let other = Login(mac: mac, stateFolder: folder)
    one.begin()
    mac.change { $0.loginItemStatus = .notRegistered }
    other.begin()
    #expect(one.isFirstLaunch)
    #expect(!other.isFirstLaunch)
    #expect(mac.requests == ["register login item"])
  }

  @Test func ofManyAppsBeginningAtOnceExactlyOneIsTheFirst() async {
    let mac = installedMac()
    let logins = (0..<24).map { _ in Login(mac: mac, stateFolder: folder) }
    await withTaskGroup(of: Void.self) { group in
      for login in logins { group.addTask { login.begin() } }
    }
    #expect(logins.filter(\.isFirstLaunch).count == 1)
    #expect(mac.requests == ["register login item"])
  }

  @Test func anItemSwitchedOffOrRemovedInMacOSStaysThatWay() async throws {
    let mac = installedMac()
    _ = launch(mac, stateFolder: folder)
    mac.change { $0.loginItemStatus = .notRegistered }
    // Through a restart and a configuration reload alike.
    let atelier = Atelier(mac, stateFolder: folder)
    atelier.login.begin()
    _ = try await atelier.config.reload()
    #expect(mac.requests == ["register login item"])
    #expect(atelier.login.status().kind == .notRegistered)
    #expect(atelier.login.status().summary == "Atelier does not open at login.")
  }

  @Test func aBuildThatIsNotInstalledLeavesTheFirstLaunchToTheInstalledApp() {
    let development = FakeMac()
    #expect(!launch(development, stateFolder: folder).isFirstLaunch)
    #expect(development.requests.isEmpty)
    let mac = installedMac()
    #expect(launch(mac, stateFolder: folder).isFirstLaunch)
    #expect(mac.requests == ["register login item"])
  }

  @Test func withNothingKeptBetweenRunsNoLaunchIsTheFirst() {
    let mac = installedMac()
    #expect(!launch(mac, stateFolder: nil).isFirstLaunch)
    #expect(mac.requests.isEmpty)
  }

  @Test func aFirstLaunchThatCannotBeRecordedAsksNothing() throws {
    // A file where the folder should be, so nothing can be written in it.
    try Data().write(to: folder)
    let mac = installedMac()
    let login = launch(mac, stateFolder: folder)
    #expect(!login.isFirstLaunch)
    #expect(mac.requests.isEmpty)
    #expect(login.status().kind == .notRegistered)
    #expect(login.status().failure?.hasPrefix("Atelier could not record") == true)
  }

  @Test func approvalStillOwedIsNotReportedAsEnabled() {
    let mac = installedMac()
    mac.change { $0.registeredLoginItemStatus = .requiresApproval }
    let status = launch(mac, stateFolder: folder).status()
    #expect(status.kind == .requiresApproval)
    #expect(status.summary == "Atelier opens at login once you allow it in Login Items.")
    #expect(status.advice != nil)
  }

  @Test func aRefusalIsExplainedUntilMacOSHasTheItem() {
    let mac = installedMac()
    mac.change { $0.loginRefusal = "Operation not permitted" }
    let login = launch(mac, stateFolder: folder)
    #expect(
      login.status().summary == "macOS did not add Atelier to Login Items: Operation not permitted")
    // Added in System Settings instead, and later removed there: the old
    // refusal is not the reason any more.
    mac.change { $0.loginItemStatus = .enabled }
    #expect(login.status().failure == nil)
    mac.change { $0.loginItemStatus = .notRegistered }
    #expect(login.status().summary == "Atelier does not open at login.")
  }

  @Test func addingItAgainIsTheUsersChoiceAndWorksOnceMacOSAllows() {
    let mac = installedMac()
    mac.change { $0.loginRefusal = "Operation not permitted" }
    let login = launch(mac, stateFolder: folder)
    mac.change { $0.loginRefusal = nil }
    login.register()
    #expect(login.status().kind == .enabled)
    #expect(login.status().failure == nil)
    #expect(mac.requests == ["register login item", "register login item"])
  }

  @Test func settingsOpenWhereMacOSKeepsTheSwitch() {
    let mac = FakeMac()
    Login(mac: mac, stateFolder: nil).openSettings()
    #expect(mac.requests == ["open login item settings"])
  }
}
