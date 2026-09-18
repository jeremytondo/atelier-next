import Foundation
import MacOS

/// How long commands wait for macOS to show what was asked of it.
package struct Patience: Sendable {
  /// Between looks.
  package var interval = Duration.milliseconds(10)
  /// For a Space to become the current one, animation included.
  package var transition = Duration.seconds(3)
  /// For a created, moved, or deleted Desktop to show in the list of Spaces.
  package var confirmation = Duration.seconds(1)
  /// For a raised window to take the keyboard.
  package var focus = Duration.seconds(1)
  /// For a launched app to show a window.
  package var launch = Duration.seconds(4)

  package init() {}
}

/// The state behind every subject: the window lists, the one-command-at-a-time
/// rule, and who is listening for changes. Everything that reads or changes
/// the lists goes through `observe`, so they are only ever brought up to date
/// by a census newer than the last one used.
actor Workspace {
  enum Change: Sendable {
    case windows, spaces
  }

  /// One census, and where the keyboard was when it was taken.
  struct Observation: Sendable {
    let snapshot: Snapshot
    let focus: Focus
    /// The display and Space receiving keyboard input.
    let display: DisplaySpaces
    let space: Space

    /// The listed window with the keyboard, if any.
    func focusedWindow(in list: [WindowIdentity]) -> WindowIdentity? {
      list.first { $0.app == focus.app && $0.id == focus.window }
    }
  }

  let mac: any Mac
  let patience: Patience
  private(set) var lists = WindowLists()
  var quickApp = QuickAppState()
  private var file: WindowListFile?
  private var hasRestored = false
  /// A command is running, and no other may.
  private var isRunning = false
  /// Atelier is leaving, and no command may start.
  private(set) var isClosed = false
  /// Whoever waits for the running command to finish.
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var censusesStarted = 0
  private var censusApplied = 0
  private var lastSeen: (displays: [DisplaySpaces], windows: [UInt64: [Window]])?
  private var listeners: [UUID: (Change, AsyncStream<Void>.Continuation)] = [:]

  init(mac: any Mac, stateFolder: URL?, patience: Patience) {
    self.mac = mac
    self.patience = patience
    file = stateFolder.map(WindowListFile.init)
  }

  /// Keeps the lists current between commands, for as long as the Mac sends
  /// hints, and the shown Quick App in step with the keyboard at all times.
  func watch() async {
    for await _ in mac.changes() {
      await followQuickApps()
      if !isRunning { _ = try? await observe() }
    }
  }

  func changes(to change: Change) -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    listeners[id] = (change, continuation)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeListener(id) }
    }
    return stream
  }

  private func removeListener(_ id: UUID) {
    listeners[id] = nil
  }

  // MARK: - Observing

  /// Takes a census, brings the lists up to date with it, and says where the
  /// keyboard is.
  func observe() async throws(AtelierError) -> Observation {
    guard mac.hasAccessibility else { throw .accessibilityRequired }
    // A census overtaken by a later one is thrown away, since the lists have
    // moved on from it; so is one whose focus and Spaces were read either
    // side of a switch. Both are rare, and neither lasts.
    for _ in 0..<3 {
      censusesStarted += 1
      let census = censusesStarted
      async let snapshotNow = mac.snapshot()
      let focus = await mac.focus()
      guard let snapshot = await snapshotNow, !snapshot.displays.isEmpty else {
        throw .unavailable
      }
      guard census > censusApplied else { continue }

      guard let display = Self.keyboardDisplay(in: snapshot.displays, focus: focus),
        let space = display.spaces.first(where: { $0.id == display.currentSpace })
      else { continue }

      censusApplied = census
      apply(snapshot, focused: focus.window)
      return Observation(snapshot: snapshot, focus: focus, display: display, space: space)
    }
    throw .unavailable
  }

  /// The display receiving keyboard input, read without a census.
  func keyboardDisplay() async -> DisplaySpaces? {
    let displays = mac.spaces()
    return Self.keyboardDisplay(in: displays, focus: await mac.focus())
  }

  /// The focused window says which Space has the keyboard, which matters
  /// when several displays each show one. The active Space answers when no
  /// window has focus or the focused window is on every Space.
  static func keyboardDisplay(in displays: [DisplaySpaces], focus: Focus) -> DisplaySpaces? {
    let shown = Set(displays.map(\.currentSpace))
    let focusedSpaces = shown.intersection(focus.windowSpaces)
    let current = focusedSpaces.count == 1 ? focusedSpaces.first! : focus.activeSpace
    return displays.first { $0.currentSpace == current }
  }

  private func apply(_ census: Snapshot, focused: UInt32?) {
    // Windows of apps under Quick App behavior are not for the lists.
    let snapshot = Snapshot(
      displays: census.displays,
      windows: census.windows.filter { !quickApp.summoned.contains($0.app) })
    if hasRestored {
      lists.reconcile(with: snapshot, focused: focused)
    } else {
      // Only now, with a census to check them against, can saved lists be believed.
      lists.restore(file?.read() ?? [:], with: snapshot, focused: focused)
      hasRestored = true
    }
    save()
    let windows = lists.byDesktop.mapValues { Self.windows($0, in: snapshot, focused: focused) }
    if let lastSeen {
      if lastSeen.displays != snapshot.displays { announce(.spaces) }
      if lastSeen.windows != windows { announce(.windows) }
    }
    lastSeen = (snapshot.displays, windows)
  }

  private func save() {
    // The lists in memory stay right whether or not the file can be written.
    try? file?.save(lists.byDesktop)
  }

  private func announce(_ change: Change) {
    for (kind, listener) in listeners.values where kind == change {
      listener.yield()
    }
  }

  static func windows(_ list: [WindowIdentity], in snapshot: Snapshot, focused: UInt32?)
    -> [Window]
  {
    list.compactMap { identity in
      snapshot.windows.first { WindowIdentity($0) == identity }.map {
        Window(
          id: $0.id, app: $0.appName, title: $0.title, isFocused: $0.id == focused,
          isVisible: $0.isOnScreen)
      }
    }
  }

  // MARK: - Commands

  /// Runs one state-changing command, handing it a fresh observation. A
  /// command that arrives while another runs is dropped.
  func run(
    _ command: (Observation) async throws(AtelierError) -> Outcome
  ) async throws(AtelierError) -> Outcome {
    guard mac.hasAccessibility else { throw .accessibilityRequired }
    guard !isRunning, !isClosed else { throw .busy }
    isRunning = true
    defer {
      finish()
      // Whatever happened should show in the lists and reach listeners, but
      // the caller need not wait for it: with an app frozen a census is slow.
      Task { _ = try? await observe() }
    }
    return try await command(try await observe())
  }

  /// Atelier is leaving, so no command may start from now on; one started
  /// now would be cut short. Busy, changing nothing, while a command runs or
  /// when Atelier is closed already.
  func close() throws(AtelierError) {
    guard !isRunning, !isClosed else { throw .busy }
    isClosed = true
  }

  /// `close`, for a quit that cannot be refused, as from the menu or from
  /// macOS. No command may start from this moment, so commands that keep
  /// arriving cannot put the ending off; the one running, which is never cut
  /// short, is waited for.
  func closeWhenIdle() async {
    isClosed = true
    while isRunning {
      await withCheckedContinuation { idleWaiters.append($0) }
    }
  }

  /// Atelier is staying after all, so commands may run again.
  func reopen() {
    isClosed = false
  }

  /// The running command is done, which whoever waits to close is told.
  private func finish() {
    isRunning = false
    let waiters = idleWaiters
    idleWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  func moveWindow(_ window: WindowIdentity, on desktop: UInt64, _ move: WindowMove) -> Bool {
    guard lists.move(window, on: desktop, move) else { return false }
    save()
    return true
  }

  func forgetList(of desktop: UInt64) {
    lists.forget(desktop: desktop)
    save()
  }

  /// True as soon as `condition` holds; false once `limit` passes without it.
  func wait(_ limit: Duration, until condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while true {
      if await condition() { return true }
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: patience.interval)
    }
  }
}
