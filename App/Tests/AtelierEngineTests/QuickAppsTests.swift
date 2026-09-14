import CoreGraphics
import Foundation
import SpaceControlCore
import Testing

@testable import AtelierEngine

private func desktop(_ id: UInt64, fullscreen: Bool = false) -> ManagedSpaceSnapshot {
  ManagedSpaceSnapshot(id: id, isFullscreen: fullscreen, rawType: fullscreen ? 4 : 0)
}

private func display(_ spaces: [ManagedSpaceSnapshot], current: UInt64) -> DisplaySpaceSnapshot {
  DisplaySpaceSnapshot(identifier: "A", currentSpaceID: current, spaces: spaces)
}

private let quick = TargetApplication(
  url: URL(fileURLWithPath: "/Applications/Quick.app"), bundleIdentifier: "com.example.quick",
  name: "Quick")
private let request = QuickToggleRequest(
  app: "Quick", expectedBundleID: quick.bundleIdentifier, size: nil)

/// One display with an editor window in front. Launching the Quick App gives
/// it process 20 and window 200 on the current Desktop.
private final class FakeWorkspace {
  struct App {
    var bundleID: String
    var hidden = false
    var windows: [UInt32] = []
  }
  struct Window {
    var frame: CGRect
    var minimized = false
    var spaces: [String]
  }
  var time: TimeInterval = 0
  var topology = [display([desktop(1), desktop(2)], current: 1)]
  var apps: [pid_t: App] = [10: App(bundleID: "com.example.editor", windows: [100])]
  var windows: [UInt32: Window] = [
    100: Window(frame: CGRect(x: 50, y: 50, width: 800, height: 600), spaces: ["1"])
  ]
  var frontmost: pid_t? = 10
  var focused: UInt32 = 100
  var visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
  var launches: [String] = []
  /// The launched app's first window, or nil for an app that shows none.
  var launchedWindowFrame: CGRect? = CGRect(x: 0, y: 0, width: 2000, height: 1200)
  var changeDesktopAfterLaunch = false
  var assignments: [(pid: pid_t, window: UInt32, required: Set<String>)] = []
  var assignmentSpreads = true
  var assignmentFails = false
  var focusWorks = true
  var hideRefused = false
  var hideIgnored = false
  var minimumSize: CGSize?

  var current: String { String(topology[0].currentSpaceID) }

  var seams: QuickAppSeams {
    QuickAppSeams(
      topology: { self.topology },
      targetDisplay: { _ in TargetDisplay(displayID: 1, topologyIdentifier: "A") },
      resolve: { name in
        guard name == "Quick" else { throw EngineError("Could not find application: \(name)") }
        return quick
      },
      running: { bundleID in self.apps.first { $0.value.bundleID == bundleID }?.key },
      frontmost: { self.frontmost.map { RunningApp(pid: $0, bundleID: self.apps[$0]?.bundleID) } },
      isRunning: { self.apps[$0] != nil },
      isHidden: { self.apps[$0]?.hidden ?? true },
      hide: { pid in
        guard !self.hideRefused else { return false }
        guard !self.hideIgnored else { return true }
        self.apps[pid]?.hidden = true
        if self.frontmost == pid {
          self.frontmost = nil
          self.focused = 0
        }
        return true
      },
      unhide: { self.apps[$0]?.hidden = false },
      launch: { target in
        self.launches.append(target.bundleIdentifier)
        var app = App(bundleID: target.bundleIdentifier)
        if let frame = self.launchedWindowFrame {
          app.windows = [200]
          self.windows[200] = Window(frame: frame, spaces: [self.current])
        }
        self.apps[20] = app
        if self.changeDesktopAfterLaunch {
          self.topology = [display([desktop(1), desktop(2)], current: 2)]
        }
        return 20
      },
      windows: { self.apps[$0]?.windows ?? [] },
      isMinimized: { self.windows[$0]?.minimized ?? false },
      unminimize: { id in
        self.windows[id]?.minimized = false
        return true
      },
      frame: { self.windows[$0]?.frame },
      move: { id, point in
        self.windows[id]?.frame.origin = point
        return true
      },
      resize: { id, size in
        var size = size
        if let minimum = self.minimumSize {
          size.width = max(size.width, minimum.width)
          size.height = max(size.height, minimum.height)
        }
        self.windows[id]?.frame.size = size
        return true
      },
      focus: { pid, id in
        guard self.focusWorks else { return }
        self.frontmost = pid
        self.focused = id
      },
      focusedWindow: { self.focused },
      spaces: { self.windows[$0]?.spaces ?? [] },
      visibleFrame: { _ in self.visible },
      assignToAllDesktops: { pid, window, _, required in
        self.assignments.append((pid, window, required))
        guard !self.assignmentFails else { throw EngineError("Dock automation failed: expected") }
        if self.assignmentSpreads { self.windows[window]?.spaces = required.sorted() }
        return "assigned"
      },
      poller: Poller(now: { self.time }, pause: { self.time += 0.04 }))
  }
}

private func failure(_ mac: FakeWorkspace, _ request: QuickToggleRequest = request) -> String? {
  do {
    _ = try QuickApps(seams: mac.seams).toggle(request)
    return nil
  } catch {
    return error.localizedDescription
  }
}

@Test func summonLaunchesPlacesAssignsAndFocuses() throws {
  let mac = FakeWorkspace()
  let apps = QuickApps(seams: mac.seams)
  let shown = try apps.toggle(request)
  #expect(mac.launches == [quick.bundleIdentifier])
  #expect(shown.action == .shown && shown.window == 200)
  #expect(shown.display == "A" && shown.space == "1" && shown.assignment == "assigned")
  #expect(mac.assignments.count == 1 && mac.assignments[0].required == ["1", "2"])
  // An oversized window shrinks to the usable area, inset by 8 points, and centers there.
  let usable = mac.visible.insetBy(dx: 8, dy: 8)
  let frame = try #require(mac.windows[200]?.frame)
  #expect(frame.size == usable.size)
  #expect(frame.midX == usable.midX && frame.midY == usable.midY)
  #expect(mac.focused == 200 && mac.frontmost == 20)
  #expect(
    apps.states[quick.bundleIdentifier]?.previous
      == RunningApp(pid: 10, bundleID: "com.example.editor"))
}

@Test func hidingRestoresTheWindowTheUserCameFrom() throws {
  let mac = FakeWorkspace()
  let apps = QuickApps(seams: mac.seams)
  _ = try apps.toggle(request)
  let hidden = try apps.toggle(request)
  #expect(
    hidden
      == QuickToggleResponse(action: .hidden, bundleID: quick.bundleIdentifier, restoredFocus: true)
  )
  #expect(mac.apps[20]?.hidden == true && mac.focused == 100 && mac.frontmost == 10)
  #expect(apps.states[quick.bundleIdentifier]?.previous == nil)
  // The next press summons the hidden app again without relaunching it.
  let again = try apps.toggle(request)
  #expect(again.action == .shown && mac.launches.count == 1)
  #expect(mac.apps[20]?.hidden == false && mac.focused == 200)
}

@Test func hidingDoesNotRestoreAWindowThatMovedMinimizedOrQuit() throws {
  for scenario in ["moved", "minimized", "quit"] {
    let mac = FakeWorkspace()
    let apps = QuickApps(seams: mac.seams)
    _ = try apps.toggle(request)
    switch scenario {
    case "moved": mac.windows[100]?.spaces = ["2"]
    case "minimized": mac.windows[100]?.minimized = true
    default: mac.apps[10] = nil
    }
    let hidden = try apps.toggle(request)
    #expect(hidden.restoredFocus == false, Comment(rawValue: scenario))
    #expect(mac.apps[20]?.hidden == true && mac.focused == 0, Comment(rawValue: scenario))
  }
}

@Test func repeatedPressWhileMinimizedKeepsTheOriginalApp() throws {
  let mac = FakeWorkspace()
  let apps = QuickApps(seams: mac.seams)
  _ = try apps.toggle(request)
  mac.windows[200]?.minimized = true
  let shown = try apps.toggle(request)
  #expect(shown.action == .shown && mac.windows[200]?.minimized == false)
  #expect(mac.launches.count == 1)
  #expect(apps.states[quick.bundleIdentifier]?.previous?.pid == 10)
  let hidden = try apps.toggle(request)
  #expect(hidden.restoredFocus == true && mac.focused == 100)
}

@Test func summonRefusesFullscreenDesktopsAndDesktopChanges() {
  let fullscreen = FakeWorkspace()
  fullscreen.topology = [display([desktop(1), desktop(90, fullscreen: true)], current: 90)]
  #expect(failure(fullscreen)?.contains("ordinary Desktop") == true)
  #expect(fullscreen.launches.isEmpty)
  let moved = FakeWorkspace()
  moved.changeDesktopAfterLaunch = true
  #expect(failure(moved)?.contains("Active Desktop changed") == true)
  #expect(moved.assignments.isEmpty)
}

@Test func summonReportsAppsWithoutAStandardWindowAfterTheTimeout() {
  let mac = FakeWorkspace()
  mac.launchedWindowFrame = nil
  #expect(failure(mac)?.contains("did not expose a standard window") == true)
  #expect(mac.time >= QuickApps.windowTimeout)
}

@Test func invalidRequestsAreRefusedBeforeTouchingTheApp() {
  let mac = FakeWorkspace()
  let cases: [(QuickToggleRequest, String)] = [
    (
      QuickToggleRequest(app: "Quick", expectedBundleID: "com.example.other", size: nil),
      "identity changed"
    ),
    (
      QuickToggleRequest(
        app: "Quick", expectedBundleID: nil, size: QuickAppSize(width: 0, height: 10)),
      "Invalid quick app size"
    ),
    (QuickToggleRequest(app: "Missing", expectedBundleID: nil, size: nil), "Could not find"),
  ]
  for (request, message) in cases {
    #expect(failure(mac, request)?.contains(message) == true, Comment(rawValue: message))
  }
  #expect(mac.launches.isEmpty)
}

@Test func requestedSizeFitsTheUsableAreaAndTheAppMinimumWins() throws {
  let mac = FakeWorkspace()
  mac.minimumSize = CGSize(width: 500, height: 400)
  let shown = try QuickApps(seams: mac.seams).toggle(
    QuickToggleRequest(
      app: "Quick", expectedBundleID: nil, size: QuickAppSize(width: 300, height: 5000)))
  let usable = mac.visible.insetBy(dx: 8, dy: 8)
  let frame = try #require(shown.frame)
  #expect(frame.w == 500 && frame.h == usable.height)
  #expect(frame.x + frame.w / 2 == usable.midX && frame.y + frame.h / 2 == usable.midY)
}

@Test func laterFailuresKeepTheWindowIdentityForTheNextPress() {
  let refused = FakeWorkspace()
  refused.assignmentFails = true
  #expect(failure(refused)?.contains("Dock automation failed") == true)

  let unverified = FakeWorkspace()
  unverified.assignmentSpreads = false
  let apps = QuickApps(seams: unverified.seams)
  do {
    _ = try apps.toggle(request)
    Issue.record("summon succeeded without membership")
  } catch {
    #expect(error.localizedDescription.contains("every Desktop"))
  }
  #expect(apps.states[quick.bundleIdentifier]?.window == 200)
  #expect(unverified.focused == 100)

  let unfocused = FakeWorkspace()
  unfocused.focusWorks = false
  #expect(failure(unfocused)?.contains("Could not focus") == true)
  #expect(unfocused.time >= 1.5)
}

@Test func hideFailuresAreReported() throws {
  for refused in [true, false] {
    let mac = FakeWorkspace()
    let apps = QuickApps(seams: mac.seams)
    _ = try apps.toggle(request)
    mac.hideRefused = refused
    mac.hideIgnored = !refused
    do {
      _ = try apps.toggle(request)
      Issue.record("hide succeeded")
    } catch {
      #expect(error.localizedDescription.contains(refused ? "Could not hide" : "verify"))
    }
  }
}
