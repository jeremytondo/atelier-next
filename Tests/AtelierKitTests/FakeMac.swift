import AtelierKit
import Foundation
import MacOS
import Synchronization

/// A Mac that does what it is asked at once, unless told to misbehave. It
/// starts with two displays: Desktops 1 and 2 on the first, showing 1, and
/// Desktop 3 beside full-screen Space 4 and Split View Space 5 on the second,
/// showing 3. `FakeMac.oneDisplay` is the Mac the Desktop commands need.
final class FakeMac: Mac, Sendable {
  struct State: Sendable {
    var hasAccessibility = true
    var displays: [DisplaySpaces] = []
    var activeSpace: UInt64 = 1
    /// Nil while Atelier itself is frontmost. It need not be in `windows`: a
    /// panel can have the keyboard.
    var focusedWindow: UInt32?
    var focusedWindowSpaces: [UInt64]?
    /// A dialog or sheet that keeps the keyboard when its app's windows are raised.
    var modalWindow: UInt32?
    /// The app of the focused window when the census does not list that window.
    var focusedApp: Int32?
    var windows: [WindowFacts] = []
    var refusesCensus = false
    var frozenApps: Set<Int32> = []
    var ignoresRaise = false
    var isMissionControlOpen: Bool? = false
    /// Says it switched Spaces and stays where it is.
    var ignoresSwitches = false
    var switchResult = SpaceDispatch.sent
    var creation: DesktopCreation?
    var createsUnseenDesktop = false
    var moveResult = SpaceDispatch.sent
    var destroyResult = SpaceDispatch.sent
    var ignoresSpaceChanges = false
    /// Runs once, just after the next census is taken: a change on the Mac
    /// that the census missed.
    var afterSnapshot: (@Sendable (inout State) -> Void)?
    /// Runs once, just after the next switch of Spaces.
    var afterSwitch: (@Sendable (inout State) -> Void)?
    var nextSpace: UInt64 = 100
    /// Everything asked of the Mac that could change it, in order.
    var requests: [String] = []
  }

  let state: Mutex<State>
  private let hints = AsyncStream.makeStream(of: Void.self)

  init(
    hasAccessibility: Bool = true, displays: [DisplaySpaces]? = nil, activeSpace: UInt64 = 1,
    shownOnSecondDisplay: UInt64 = 3, focusedWindow: UInt32? = nil,
    focusedWindowSpaces: [UInt64]? = nil, windows: [WindowFacts] = [],
    refusesCensus: Bool = false
  ) {
    let displays =
      displays ?? [
        DisplaySpaces(
          id: "first", currentSpace: 1,
          spaces: [Space(id: 1, isDesktop: true), Space(id: 2, isDesktop: true)]),
        DisplaySpaces(
          id: "second", currentSpace: shownOnSecondDisplay,
          spaces: [
            Space(id: 3, isDesktop: true), Space(id: 4, isDesktop: false),
            Space(id: 5, isDesktop: false),
          ]),
      ]
    state = Mutex(
      State(
        hasAccessibility: hasAccessibility, displays: displays, activeSpace: activeSpace,
        focusedWindow: focusedWindow, focusedWindowSpaces: focusedWindowSpaces, windows: windows,
        refusesCensus: refusesCensus))
  }

  /// One display whose Spaces are numbered from 1 in order, showing `current`.
  /// `notDesktops` are full-screen or Split View Spaces.
  static func oneDisplay(
    spaces: ClosedRange<UInt64> = 1...3, notDesktops: Set<UInt64> = [], current: UInt64 = 1,
    focusedWindow: UInt32? = nil, windows: [WindowFacts] = []
  ) -> FakeMac {
    FakeMac(
      displays: [
        DisplaySpaces(
          id: "only", currentSpace: current,
          spaces: spaces.map { Space(id: $0, isDesktop: !notDesktops.contains($0)) })
      ], activeSpace: current, focusedWindow: focusedWindow, windows: windows)
  }

  func change(_ body: (inout State) -> Void) {
    state.withLock { body(&$0) }
  }

  /// Tells Atelier to look, as the real Mac does when it notices a change.
  func hint() {
    hints.continuation.yield()
  }

  var requests: [String] { state.withLock(\.requests) }
  var spaceOrder: [UInt64] { state.withLock { $0.displays[0].spaces.map(\.id) } }
  var currentSpace: UInt64 { state.withLock { $0.displays[0].currentSpace } }
  var focusedWindow: UInt32? { state.withLock(\.focusedWindow) }

  // MARK: - Mac

  var hasAccessibility: Bool { state.withLock(\.hasAccessibility) }

  func requestAccessibility() {}

  func focus() async -> Focus {
    state.withLock { state in
      let facts = state.windows.first { $0.id == state.focusedWindow }
      return Focus(
        app: facts?.app ?? state.focusedApp ?? state.focusedWindow.map(Int32.init),
        window: state.focusedWindow,
        windowIsOrdinary: facts?.report == .ordinary,
        windowSpaces: state.focusedWindowSpaces ?? facts?.spaces ?? [],
        activeSpace: state.activeSpace)
    }
  }

  func snapshot() async -> Snapshot? {
    state.withLock { state in
      guard !state.refusesCensus else { return nil }
      let windows = state.windows.map { window in
        state.frozenApps.contains(window.app) ? window.with(report: .unanswered) : window
      }
      let snapshot = Snapshot(displays: state.displays, windows: windows)
      let afterSnapshot = state.afterSnapshot
      state.afterSnapshot = nil
      afterSnapshot?(&state)
      return snapshot
    }
  }

  func changes() -> AsyncStream<Void> { hints.stream }

  func spaces() -> [DisplaySpaces] { state.withLock(\.displays) }

  func isMissionControlOpen() async -> Bool? { state.withLock(\.isMissionControlOpen) }

  func switchSpace(to space: UInt64, on display: String, expecting: [DisplaySpaces]) async
    -> SpaceDispatch
  {
    state.withLock { state in
      guard state.displays == expecting else { return .changed }
      state.requests.append("switch to \(space)")
      guard state.switchResult == .sent, !state.ignoresSwitches else { return state.switchResult }
      state.show(space)
      let afterSwitch = state.afterSwitch
      state.afterSwitch = nil
      afterSwitch?(&state)
      return .sent
    }
  }

  func createDesktop(expecting: [DisplaySpaces]) async -> DesktopCreation {
    state.withLock { state in
      guard state.displays == expecting else { return .changed }
      state.requests.append("create")
      if let creation = state.creation { return creation }
      let id = state.nextSpace
      state.nextSpace += 1
      if !state.createsUnseenDesktop {
        state.replaceSpaces { $0 + [Space(id: id, isDesktop: true)] }
      }
      return .created(id)
    }
  }

  func moveSpace(
    _ id: UInt64, toIndex index: Int, onDisplay display: String, expecting: [DisplaySpaces]
  ) async -> SpaceDispatch {
    state.withLock { state in
      guard state.displays == expecting else { return .changed }
      state.requests.append("move \(id) to \(index)")
      guard state.moveResult == .sent, !state.ignoresSpaceChanges else { return state.moveResult }
      state.replaceSpaces { spaces in
        var spaces = spaces
        guard let from = spaces.firstIndex(where: { $0.id == id }) else { return spaces }
        spaces.insert(spaces.remove(at: from), at: index)
        return spaces
      }
      return .sent
    }
  }

  func destroySpace(_ id: UInt64, expecting: [DisplaySpaces]) async -> SpaceDispatch {
    state.withLock { state in
      guard state.displays == expecting else { return .changed }
      state.requests.append("destroy \(id)")
      guard state.destroyResult == .sent, !state.ignoresSpaceChanges else {
        return state.destroyResult
      }
      let shown = state.displays[0].currentSpace
      state.replaceSpaces { $0.filter { $0.id != id } }
      // macOS moves the windows of a deleted Desktop to the one being shown.
      state.windows = state.windows.map { $0.spaces == [id] ? $0.with(spaces: [shown]) : $0 }
      return .sent
    }
  }

  func raise(window: UInt32, of app: Int32) async -> RaiseResult {
    state.withLock { state in
      state.requests.append("raise \(window)")
      guard !state.frozenApps.contains(app) else { return .unanswered }
      guard let index = state.windows.firstIndex(where: { $0.id == window && $0.app == app })
      else { return .closed }
      guard !state.ignoresRaise else { return .asked }
      state.windows[index] = state.windows[index].with(isOnScreen: true)
      state.focusedWindow = state.modalWindow ?? window
      state.focusedApp = app
      return .asked
    }
  }
}

extension FakeMac.State {
  mutating func show(_ space: UInt64) {
    displays = displays.map { display in
      display.spaces.contains { $0.id == space }
        ? DisplaySpaces(id: display.id, currentSpace: space, spaces: display.spaces) : display
    }
    activeSpace = space
  }

  /// Changes the Spaces of the first display, as the Desktop commands do.
  mutating func replaceSpaces(_ change: ([Space]) -> [Space]) {
    displays[0] = DisplaySpaces(
      id: displays[0].id, currentSpace: displays[0].currentSpace,
      spaces: change(displays[0].spaces))
  }
}

extension WindowFacts {
  func with(
    spaces: [UInt64]? = nil, isOnScreen: Bool? = nil, report: Report? = nil,
    appLaunched: Double?? = nil
  ) -> WindowFacts {
    WindowFacts(
      id: id, app: app, appLaunched: appLaunched ?? self.appLaunched, appName: appName,
      title: title, spaces: spaces ?? self.spaces, isOnScreen: isOnScreen ?? self.isOnScreen,
      report: report ?? self.report)
  }
}

/// Window `id` of an app of its own, whose process number is also `id`.
func window(
  _ id: UInt32, on spaces: [UInt64] = [1], onScreen: Bool = true, ordinary: Bool = true
) -> WindowFacts {
  WindowFacts(
    id: id, app: Int32(id), appLaunched: 1000, appName: "App \(id)", title: "Window \(id)",
    spaces: spaces, isOnScreen: onScreen, report: ordinary ? .ordinary : .other)
}

extension Patience {
  /// Short enough that a test of something never happening stays quick.
  static var short: Patience {
    var patience = Patience()
    patience.interval = .milliseconds(1)
    patience.transition = .milliseconds(30)
    patience.confirmation = .milliseconds(30)
    patience.focus = .milliseconds(30)
    return patience
  }
}

extension Atelier {
  init(_ mac: FakeMac, stateFolder: URL? = nil) {
    self.init(mac: mac, stateFolder: stateFolder, patience: .short)
  }

  /// The current Desktop's window numbers in slot order; nil off a Desktop.
  func slots() async throws -> [UInt32]? {
    guard case .desktop(let windows) = try await windows.list() else { return nil }
    return windows.map(\.id)
  }
}
