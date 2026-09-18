import Foundation
import MacOS
import Testing

@testable import AtelierKit

/// Summoning, hiding, and the return to ordinary use, on a Mac with one
/// display showing Desktop 1 of two, an editor focused on it, and 1Password
/// installed but not running unless a test starts it.
@Suite struct QuickAppTests {
  private static let passwords = AppReference(
    url: URL(filePath: "/Applications/1Password.app"), bundleID: "com.1password", name: "1Password")
  private static let notes = AppReference(
    url: URL(filePath: "/Applications/Notes.app"), bundleID: "com.apple.Notes", name: "Notes")
  private static let config = """
    [[quick-apps]]
    app = "1Password"
    leader = "a p"
    shortcut = "ctrl+option+p"

    [[quick-apps]]
    app = "com.apple.Notes"
    size = { width = 900, height = 650 }

    [[quick-apps]]
    app = "Missing"
    """

  private let folder = FileManager.default.temporaryDirectory.appending(
    path: "atelier-quick-\(UUID().uuidString.prefix(8))")

  /// The editor is window 1, process 1, on Desktop 1. A launched 1Password
  /// opens window 200 on the current Desktop, 1200 × 900 points.
  private func mac(passwordsRunning: Bool = false, hidden: Bool = false) -> FakeMac {
    let mac = FakeMac.oneDisplay(spaces: 1...2, current: 1, focusedWindow: 1, windows: [window(1)])
    mac.change { state in
      state.installed = [Self.passwords, Self.notes]
      state.onLaunch = { state, pid in
        guard !state.windows.contains(where: { $0.app == pid }) else { return }
        let space = state.displays[0].currentSpace
        state.windows.append(
          WindowFacts(
            id: 200, app: pid, appLaunched: 2000, appName: "1Password", title: "Vault",
            spaces: [space], isOnScreen: true, report: .ordinary))
        state.frames[200] = CGRect(x: 100, y: 100, width: 1200, height: 900)
      }
      if passwordsRunning {
        state.apps[20] = (Self.passwords, hidden)
        state.windows.append(
          WindowFacts(
            id: 200, app: 20, appLaunched: 2000, appName: "1Password", title: "Vault",
            spaces: [1], isOnScreen: !hidden, report: .ordinary))
        state.frames[200] = CGRect(x: 100, y: 100, width: 1200, height: 900)
      }
    }
    return mac
  }

  private func start(_ mac: FakeMac) async throws -> Atelier {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "config.toml")
    try Self.config.write(to: file, atomically: true, encoding: .utf8)
    let atelier = Atelier(mac, configFile: file)
    await atelier.config.ready()
    return atelier
  }

  @Test func summonLaunchesQuietlyPlacesAndFocuses() async throws {
    let mac = mac()
    let atelier = try await start(mac)
    #expect(try await atelier.quickApps.toggle("1Password") == .changed)
    #expect(mac.state.withLock(\.launches) == ["1Password"])
    // Larger than the floating size, so held to it, and centered in the usable area.
    let frame = mac.state.withLock { $0.frames[200] }
    #expect(frame?.size == CGSize(width: 1000, height: 687))
    #expect(frame?.midX == 720)
    #expect(frame?.midY == 462.5)
    #expect(mac.focusedWindow == 200)
    let list = await atelier.quickApps.list()
    #expect(list.map(\.isShown) == [true, false, false])
    #expect(
      list[2].problem
        == "No app named \"Missing\" was found. Give a name, bundle identifier, or path.")
    #expect(list[0].leader == "a p")
    #expect(list[0].shortcut == "⌃⌥p")
    // Its window is not in the Desktop's list.
    #expect(try await atelier.slots() == [1])
  }

  @Test func togglingTheShownAppHidesItAppWideWithoutRestoringFocus() async throws {
    let mac = mac(passwordsRunning: true)
    let atelier = try await start(mac)
    _ = try await atelier.quickApps.toggle("1Password")
    #expect(mac.focusedWindow == 200)
    #expect(try await atelier.quickApps.toggle("1Password") == .changed)
    #expect(mac.isAppHidden(20) == true)
    #expect(mac.focusedWindow == nil)
    #expect(await atelier.quickApps.list()[0].isShown == false)
    #expect(mac.state.withLock(\.launches).isEmpty)
    // Hidden, it stays out of the list; summoned again, it comes back without a launch.
    #expect(try await atelier.slots() == [1])
    #expect(try await atelier.quickApps.toggle("1Password") == .changed)
    #expect(mac.isAppHidden(20) == false)
    #expect(mac.focusedWindow == 200)
    #expect(mac.state.withLock(\.launches).isEmpty)
  }

  @Test func aWindowOnAnotherDesktopIsMovedHereNotVisited() async throws {
    let mac = mac(passwordsRunning: true, hidden: true)
    mac.change { state in
      state.windows = state.windows.map { $0.id == 200 ? $0.with(spaces: [2]) : $0 }
    }
    let atelier = try await start(mac)
    #expect(try await atelier.quickApps.toggle("1Password") == .changed)
    #expect(mac.spaces(ofWindow: 200) == [1])
    #expect(mac.currentSpace == 1)
    #expect(mac.requests.contains("move window 200 to 1"))
    #expect(!mac.requests.contains { $0.hasPrefix("switch") })
  }

  @Test(arguments: [true, false])
  func aMoveThatDoesNotShowIsAFailureAndOnlyWhatAtelierBroughtOutIsPutAway(hidden: Bool)
    async throws
  {
    let mac = mac(passwordsRunning: true, hidden: hidden)
    mac.change { state in
      state.windows = state.windows.map { $0.id == 200 ? $0.with(spaces: [2]) : $0 }
      state.ignoresSpaceChanges = true
    }
    let atelier = try await start(mac)
    await #expect(
      throws: AtelierError.failed("macOS did not move the 1Password window to this Desktop.")
    ) {
      try await atelier.quickApps.toggle("1Password")
    }
    // An app the user had out stays out; one Atelier unhid goes back.
    #expect(mac.isAppHidden(20) == hidden)
    #expect(await atelier.quickApps.list()[0].isShown == false)
    #expect(try await atelier.slots() == [1])
  }

  @Test func aDesktopChangeDuringSummonStopsIt() async throws {
    let mac = mac(passwordsRunning: true, hidden: true)
    mac.change { state in
      state.afterSnapshot = { $0.show(2) }
    }
    let atelier = try await start(mac)
    await #expect(
      throws: AtelierError.targetChanged("The Desktop changed, so 1Password was not shown.")
    ) {
      try await atelier.quickApps.toggle("1Password")
    }
    #expect(mac.isAppHidden(20) == true)
    #expect(mac.focusedWindow == 1)
  }

  @Test func summoningAnotherHidesTheShownOneFirst() async throws {
    let mac = mac(passwordsRunning: true)
    mac.change { state in
      state.apps[30] = (Self.notes, false)
      state.windows.append(
        WindowFacts(
          id: 300, app: 30, appLaunched: 3000, appName: "Notes", title: "", spaces: [1],
          isOnScreen: true, report: .ordinary))
      state.frames[300] = CGRect(x: 0, y: 0, width: 500, height: 400)
    }
    let atelier = try await start(mac)
    _ = try await atelier.quickApps.toggle("1Password")
    #expect(try await atelier.quickApps.toggle("com.apple.Notes") == .changed)
    #expect(mac.isAppHidden(20) == true)
    #expect(mac.focusedWindow == 300)
    // An explicit size is asked for, within the display.
    #expect(mac.state.withLock { $0.frames[300]?.size } == CGSize(width: 900, height: 650))
    #expect(await atelier.quickApps.list().map(\.isShown) == [false, true, false])
    // One that cannot be hidden keeps the other from showing.
    mac.change { $0.ignoresHiding = true }
    await #expect(throws: AtelierError.failed("Could not hide Notes Quick App.")) {
      try await atelier.quickApps.toggle("1Password")
    }
  }

  @Test func theAppMinimumSizeWins() async throws {
    let mac = mac(passwordsRunning: true)
    mac.change { $0.minimumSizes[200] = CGSize(width: 1100, height: 400) }
    let atelier = try await start(mac)
    _ = try await atelier.quickApps.toggle("1Password")
    let frame = mac.state.withLock { $0.frames[200] }
    #expect(frame?.size == CGSize(width: 1100, height: 687))
    #expect(frame?.midX == 720)
  }

  @Test func switchingAwayOrChangingSpaceHidesItAndOpeningNormallyMakesItOrdinary() async throws {
    let mac = mac(passwordsRunning: true)
    let atelier = try await start(mac)
    _ = try await atelier.quickApps.toggle("1Password")
    // The keyboard goes to the editor.
    mac.change { $0.focusedWindow = 1 }
    mac.hint()
    #expect(await eventually { mac.isAppHidden(20) == true })
    #expect(try await atelier.slots() == [1])
    // Opened from the Dock: frontmost without Atelier, so an ordinary app again.
    mac.change { state in
      state.apps[20]?.hidden = false
      state.windows = state.windows.map { $0.id == 200 ? $0.with(isOnScreen: true) : $0 }
      state.focusedWindow = 200
    }
    mac.hint()
    #expect(await eventually { (try? await atelier.slots()) == [1, 200] })
    // Focus elsewhere no longer hides it.
    mac.change { $0.focusedWindow = 1 }
    mac.hint()
    _ = try await atelier.slots()
    #expect(mac.isAppHidden(20) == false)
    // Summoned again while frontmost and ordinary: adopted, not taken as shown.
    mac.change { $0.focusedWindow = 200 }
    #expect(try await atelier.quickApps.toggle("1Password") == .changed)
    #expect(mac.isAppHidden(20) == false)
    #expect(await atelier.quickApps.list()[0].isShown)
    // A Space change hides it.
    mac.change { $0.show(2) }
    mac.hint()
    #expect(await eventually { mac.isAppHidden(20) == true })
  }

  @Test func failuresAreWorded() async throws {
    let mac = mac()
    let atelier = try await start(mac)
    await #expect(throws: AtelierError.failed(QuickApps.notFound("Missing"))) {
      try await atelier.quickApps.toggle("Missing")
    }
    mac.change { $0.refusesLaunch = true }
    await #expect(throws: AtelierError.failed("1Password would not launch.")) {
      try await atelier.quickApps.toggle("1Password")
    }
    mac.change { state in
      state.refusesLaunch = false
      state.onLaunch = nil
    }
    await #expect(throws: AtelierError.failed("1Password did not open a window in time.")) {
      try await atelier.quickApps.toggle("1Password")
    }
    mac.change { $0.show(2) }
    mac.change { state in
      state.displays = [
        DisplaySpaces(
          id: "only", currentSpace: 2,
          spaces: [Space(id: 1, isDesktop: true), Space(id: 2, isDesktop: false)])
      ]
      state.activeSpace = 2
    }
    await #expect(
      throws: AtelierError.failed(
        "Quick Apps appear on Desktops; leave the full-screen or Split View Space.")
    ) {
      try await atelier.quickApps.toggle("1Password")
    }
  }

  @Test func theShortcutAndTheLeaderSummonTheAppToo() async throws {
    let mac = mac()
    let atelier = try await start(mac)
    mac.press(chord("ctrl+option+p"))
    #expect(await eventually { mac.focusedWindow == 200 })
    #expect(await atelier.quickApps.list()[0].isShown)
    _ = try await atelier.leader.open()
    mac.type("a")
    _ = await eventually { await atelier.leader.state()?.title == "Quick Apps" }
    let entries = await atelier.leader.state()?.entries
    #expect(entries?.map(\.label) == ["1Password"])
    #expect(entries?.first?.hint == "⌃⌥p")
    #expect(entries?.first?.unavailable == nil)
    // The same key from the menu hides it, and the menu closes.
    mac.type("p")
    #expect(await eventually { mac.isAppHidden(50) == true })
    #expect(await eventually { await atelier.leader.state() == nil })
  }

  @Test func anAppLaunchedForAFailedSummonIsPutAway() async throws {
    let mac = mac()
    mac.change { state in
      state.afterSnapshot = { $0.show(2) }
    }
    let atelier = try await start(mac)
    await #expect(throws: AtelierError.self) { try await atelier.quickApps.toggle("1Password") }
    #expect(mac.state.withLock(\.launches) == ["1Password"])
    #expect(mac.isAppHidden(50) == true)
  }

  @Test func aShownAppThatQuitIsForgotten() async throws {
    let mac = mac(passwordsRunning: true)
    let atelier = try await start(mac)
    _ = try await atelier.quickApps.toggle("1Password")
    mac.change { state in
      state.apps[20] = nil
      state.windows.removeAll { $0.app == 20 }
      state.focusedWindow = 1
    }
    mac.hint()
    #expect(await eventually { await atelier.quickApps.list()[0].isShown == false })
    // Summoning again launches afresh rather than trying to hide a ghost.
    #expect(try await atelier.quickApps.toggle("1Password") == .changed)
    #expect(mac.state.withLock(\.launches) == ["1Password"])
  }
}
