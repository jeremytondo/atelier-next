import Client
import Foundation
import MacOS
import Synchronization

@testable import AtelierKit

/// A Mac that does what it is asked at once, unless told to misbehave. It
/// starts with two displays: Desktops 1 and 2 on the first, showing 1, and
/// Desktop 3 beside full-screen Space 4 and Split View Space 5 on the second,
/// showing 3. `FakeMac.oneDisplay` is the Mac the Desktop commands need.
final class FakeMac: Mac, Sendable {
  struct State: Sendable {
    var hasAccessibility = true
    var isInstalled = false
    var loginItemStatus = LoginItemStatus.notRegistered
    /// Why macOS refuses to add the login item; nil to add it.
    var loginRefusal: String?
    /// What a login item that was added becomes: enabled, or awaiting approval.
    var registeredLoginItemStatus = LoginItemStatus.enabled
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
    /// The global shortcuts registered now.
    var hotKeys: [Chord] = []
    var refusedHotKeys: [Chord: String] = [:]
    /// macOS's own Space-switching shortcuts: Control with a digit or arrow.
    var spaceChords: [Chord] =
      [Chord([.control], "left"), Chord([.control], "right")]
      + (1...9).map { Chord([.control], "\($0)") }
    /// Each app's Window menu; an app not listed has no menu bar.
    var windowMenus: [Int32: [Arrangement: ArrangementItem]] = [:]
    var openedFiles: [URL] = []
    /// The key listener now, if one is on.
    var listener: FakeListener?
    var refusesListening = false
    /// Every start and stop of a key listener, in order.
    var listening: [String] = []
    /// Apps on disk, by the references that find them.
    var installed: [AppReference] = []
    /// Running apps by process number: hidden or not.
    var apps: [Int32: (app: AppReference, hidden: Bool)] = [:]
    var launches: [String] = []
    /// Runs when an app launches, given its process number, to give it windows.
    var onLaunch: (@Sendable (inout State, Int32) -> Void)?
    var nextPid: Int32 = 50
    var refusesLaunch = false
    var refusesHiding = false
    var ignoresHiding = false
    var frames: [UInt32: CGRect] = [:]
    /// The smallest size an app allows its window.
    var minimumSizes: [UInt32: CGSize] = [:]
    var usableFrames: [String: CGRect] = [
      "only": CGRect(x: 0, y: 25, width: 1440, height: 875),
      "first": CGRect(x: 0, y: 25, width: 1440, height: 875),
    ]
  }

  /// A key listener the test drives.
  final class FakeListener: KeyListening, Sendable {
    let decide: @Sendable (KeyEvent) -> KeyDecision
    let onStop: @Sendable () -> Void

    init(
      decide: @escaping @Sendable (KeyEvent) -> KeyDecision, onStop: @escaping @Sendable () -> Void
    ) {
      self.decide = decide
      self.onStop = onStop
    }

    func stop() {
      onStop()
    }
  }

  let state: Mutex<State>
  private let hints = AsyncStream.makeStream(of: Void.self)
  private let hotKeyPressed = AsyncStream.makeStream(of: Chord.self)
  private let modifiers = AsyncStream.makeStream(of: Chord.Modifiers.self)

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
  var hotKeys: [Chord] { state.withLock(\.hotKeys) }

  /// The user presses a registered shortcut.
  func press(_ chord: Chord) {
    hotKeyPressed.continuation.yield(chord)
  }

  /// The user holds these modifiers.
  func hold(_ modifiers: Chord.Modifiers) {
    self.modifiers.continuation.yield(modifiers)
  }

  var isListening: Bool { state.withLock { $0.listener != nil } }
  var listening: [String] { state.withLock(\.listening) }

  /// A key event while a listener is on; nil when none is. Returns whether
  /// the event went on to apps.
  @discardableResult
  func type(_ event: KeyEvent) -> Bool? {
    guard let listener = state.withLock(\.listener) else { return nil }
    return listener.decide(event) == .pass
  }

  @discardableResult
  func type(_ text: String) -> Bool? {
    type(.keyDown(chord(text)))
  }

  // MARK: - Mac

  var hasAccessibility: Bool { state.withLock(\.hasAccessibility) }

  func requestAccessibility() {}

  var isInstalled: Bool { state.withLock(\.isInstalled) }

  var appPath: String { "/Applications/Atelier.app" }

  func terminate() {
    state.withLock { $0.requests.append("terminate") }
  }

  var loginItemStatus: LoginItemStatus { state.withLock(\.loginItemStatus) }

  func registerLoginItem() -> String? {
    state.withLock { state in
      state.requests.append("register login item")
      if state.loginRefusal == nil { state.loginItemStatus = state.registeredLoginItemStatus }
      return state.loginRefusal
    }
  }

  func openLoginItemSettings() {
    state.withLock { $0.requests.append("open login item settings") }
  }

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

  func moveWindow(_ id: UInt32, toSpace space: UInt64, expecting: [DisplaySpaces]) async
    -> SpaceDispatch
  {
    state.withLock { state in
      guard state.displays == expecting else { return .changed }
      state.requests.append("move window \(id) to \(space)")
      guard state.moveResult == .sent, !state.ignoresSpaceChanges else { return state.moveResult }
      state.windows = state.windows.map { $0.id == id ? $0.with(spaces: [space]) : $0 }
      return .sent
    }
  }

  func spaces(ofWindow id: UInt32) -> [UInt64] {
    state.withLock { $0.windows.first { $0.id == id }?.spaces ?? [] }
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
    app: Int32? = nil, spaces: [UInt64]? = nil, isOnScreen: Bool? = nil, report: Report? = nil,
    appLaunched: Double?? = nil
  ) -> WindowFacts {
    WindowFacts(
      id: id, app: app ?? self.app, appLaunched: appLaunched ?? self.appLaunched, appName: appName,
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
    patience.launch = .milliseconds(60)
    return patience
  }
}

extension Atelier {
  init(_ mac: FakeMac, stateFolder: URL? = nil, configFile: URL? = nil) {
    self.init(mac: mac, stateFolder: stateFolder, configFile: configFile, patience: .short)
  }

  /// The current Desktop's window numbers in slot order; nil off a Desktop.
  func slots() async throws -> [UInt32]? {
    guard case .desktop(let windows, _) = try await windows.list() else { return nil }
    return windows.map(\.id)
  }
}

extension FakeMac {
  func arrangements(of app: Int32) async -> [Arrangement: ArrangementItem]? {
    state.withLock { state in
      state.frozenApps.contains(app) ? nil : state.windowMenus[app]
    }
  }

  func arrange(_ arrangement: Arrangement, in app: Int32, window: UInt32) async -> ArrangeResult {
    state.withLock { state in
      guard !state.frozenApps.contains(app), let menu = state.windowMenus[app] else {
        return .unanswered
      }
      guard let item = menu[arrangement] else { return .missing }
      guard item.isEnabled else { return .disabled }
      guard state.focusedWindow == window else { return .windowChanged }
      state.requests.append("arrange \(arrangement.rawValue)")
      return .pressed
    }
  }

  func registerHotKeys(_ chords: [Chord]) async -> [Chord: String] {
    state.withLock { state in
      let refused = state.refusedHotKeys.filter { chords.contains($0.key) }
      state.hotKeys = chords.filter { refused[$0] == nil }
      return refused
    }
  }

  func hotKeyPresses() -> AsyncStream<Chord> { hotKeyPressed.stream }

  func spaceSwitchingChords() async -> [Chord] { state.withLock(\.spaceChords) }

  func open(_ file: URL) -> Bool {
    state.withLock { $0.openedFiles.append(file) }
    return true
  }

  func findApp(_ reference: String) -> AppReference? {
    state.withLock { state in
      state.installed.first {
        $0.name == reference || $0.bundleID == reference || $0.url.path == reference
      }
    }
  }

  func runningApp(_ app: AppReference) -> Int32? {
    state.withLock { $0.apps.first { $0.value.app == app }?.key }
  }

  func launch(_ app: AppReference) async -> Int32? {
    state.withLock { state in
      state.launches.append(app.name)
      guard !state.refusesLaunch else { return nil }
      if let pid = state.apps.first(where: { $0.value.app == app })?.key {
        state.onLaunch?(&state, pid)
        return pid
      }
      let pid = state.nextPid
      state.nextPid += 1
      state.apps[pid] = (app, false)
      state.onLaunch?(&state, pid)
      return pid
    }
  }

  func isAppHidden(_ pid: Int32) -> Bool? {
    state.withLock { $0.apps[pid]?.hidden }
  }

  func setAppHidden(_ pid: Int32, _ hidden: Bool) -> Bool {
    state.withLock { state in
      guard state.apps[pid] != nil, !state.refusesHiding else { return false }
      state.requests.append(hidden ? "hide \(pid)" : "unhide \(pid)")
      guard !state.ignoresHiding else { return true }
      state.apps[pid]?.hidden = hidden
      state.windows = state.windows.map { $0.app == pid ? $0.with(isOnScreen: !hidden) : $0 }
      if hidden,
        state.focusedApp == pid
          || state.windows.contains(where: { $0.id == state.focusedWindow && $0.app == pid })
      {
        state.focusedWindow = nil
        state.focusedApp = nil
      }
      return true
    }
  }

  func frame(ofWindow id: UInt32, in app: Int32) async -> CGRect? {
    state.withLock { state in
      guard !state.frozenApps.contains(app),
        state.windows.contains(where: { $0.id == id && $0.app == app })
      else { return nil }
      return state.frames[id]
    }
  }

  func setFrame(_ frame: CGRect, ofWindow id: UInt32, in app: Int32) async -> Bool {
    state.withLock { state in
      guard state.frames[id] != nil, !state.frozenApps.contains(app),
        state.windows.contains(where: { $0.id == id && $0.app == app })
      else { return false }
      let minimum = state.minimumSizes[id] ?? .zero
      state.frames[id] = CGRect(
        origin: frame.origin,
        size: CGSize(
          width: max(frame.width, minimum.width), height: max(frame.height, minimum.height)))
      state.requests.append("frame \(id)")
      return true
    }
  }

  func usableFrame(ofDisplay id: String) async -> CGRect? {
    state.withLock { $0.usableFrames[id] }
  }

  func listenToKeys(_ decide: @escaping @Sendable (KeyEvent) -> KeyDecision) async
    -> (any KeyListening)?
  {
    state.withLock { state in
      guard !state.refusesListening else { return nil }
      let listener = FakeListener(decide: decide) { [self] in
        self.state.withLock { state in
          state.listener = nil
          state.listening.append("stop")
        }
      }
      state.listener = listener
      state.listening.append("start")
      return listener
    }
  }

  func modifierChanges() async -> AsyncStream<Chord.Modifiers> { modifiers.stream }
}

/// True as soon as `condition` holds, within a second; false when it never does.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
  for _ in 0..<200 {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}

func chord(_ text: String) -> Chord {
  try! KeyGrammar.chord(text, bare: true)
}

extension Request {
  /// `send` from a thread of its own. `send` blocks until the reply comes,
  /// and the server words its reply on Swift's shared threads, so a test that
  /// blocked one of those for each request could leave none to answer: on a
  /// Mac with three cores, three such tests at once wait on each other until
  /// the socket gives up.
  func sent(to path: String) async throws -> Reply {
    try await withCheckedThrowingContinuation { continuation in
      Thread.detachNewThread {
        continuation.resume(with: Result { try send(to: path) })
      }
    }
  }
}
