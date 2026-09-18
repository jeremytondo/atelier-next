import Foundation
import MacOS
import Synchronization

/// One row of the leader menu as it stands right now.
public struct LeaderEntry: Equatable, Identifiable, Sendable {
  public var id: String { key }
  /// The key to press, as a menu prints it: `⇧←`.
  public let key: String
  public let label: String
  public let isSubmenu: Bool
  /// A shortcut that reaches the same command without the leader, when there is one.
  public let hint: String?
  /// Nil when the command can run now; otherwise why not.
  public let unavailable: String?
}

/// The open leader menu.
public struct LeaderState: Equatable, Sendable {
  /// The submenu path, such as `Windows › Arrange`, or `Atelier` at the top.
  public let title: String
  public let entries: [LeaderEntry]
  /// A word about the last key, for a moment.
  public let feedback: String?
  /// The display receiving keyboard input, where the menu belongs.
  public let display: String
  /// False before the configured delay has passed, and while a command runs.
  public let isShown: Bool
}

/// The `leader` subject: the menu that opens on the leader key and takes
/// one sequence of keys to a command. While it is open every key goes to
/// it and nowhere else, except clicks, Cmd-Tab, and a switch of apps, which
/// close it and go where they were aimed. The key listener exists only while
/// the menu is open and is off while a command runs.
public struct Leader: Sendable {
  let session: LeaderSession

  /// Opens the menu, or returns it to the top when already open.
  package func open() async throws(AtelierError) -> Outcome {
    try await session.open()
  }

  package func close() async {
    await session.exit()
  }

  /// Nil while the menu is closed.
  public func state() async -> LeaderState? {
    await session.state
  }

  /// Yields whenever `state` changed.
  public func changes() async -> AsyncStream<Void> {
    await session.changes()
  }
}

/// How long a word of feedback stays in the menu.
let feedbackTime = Duration.milliseconds(1500)

actor LeaderSession {
  /// What the key listener asks of the session, off the listener's thread.
  private enum Act: Sendable {
    case render
    case run(Command)
    case explain(String)
    case exit
    /// A key was pressed; the inactivity clock starts over.
    case activity
  }

  /// What the listener needs to decide at once, on its own thread.
  private struct Keys: Sendable {
    let root: Menu
    let leaderChord: Chord?
    var path: [Chord] = []
    /// The leader's own modifiers are ignored until released once.
    var heldLeader = true

    var menu: Menu { Self.menu(root, at: path) }

    static func menu(_ root: Menu, at path: [Chord]) -> Menu {
      path.reduce(root) { menu, chord in
        for case .submenu(let key, let submenu) in menu.entries where key == chord {
          return submenu
        }
        return menu
      }
    }
  }

  /// The keys, shared between the session and the listener's thread.
  private final class SharedKeys: Sendable {
    private let keys: Mutex<Keys>

    init(_ keys: Keys) {
      self.keys = Mutex(keys)
    }

    func withLock<T: Sendable>(_ body: (inout sending Keys) -> sending T) -> T {
      keys.withLock(body)
    }
  }

  /// One time the menu is open, from the leader key to its closing.
  private struct Opening {
    let generation: Int
    let configuration: Configuration
    let display: String
    let keys: SharedKeys
    var listener: (any KeyListening)?
    /// Ends the listener's acts with it, so their reader finishes on its own.
    var acts: AsyncStream<Act>.Continuation?
    var delay: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    var feedbackTimer: Task<Void, Never>?
    var feedback: String?
    var isShown: Bool
    var title = ""
    var entries: [LeaderEntry] = []
    /// Counts the menu refreshes, so a slow one never overwrites a newer one.
    var refreshes = 0
  }

  private let mac: any Mac
  private let workspace: Workspace
  private let store: ConfigStore
  private let runner: CommandRunner
  private var opening: Opening?
  /// Counts the openings, and every closing, so that anything from before is stale.
  private var generation = 0
  private(set) var state: LeaderState?
  private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]

  init(mac: any Mac, workspace: Workspace, store: ConfigStore, runner: CommandRunner) {
    self.mac = mac
    self.workspace = workspace
    self.store = store
    self.runner = runner
    // A menu open across a reload would run the keys of the old configuration.
    Task { [weak self] in
      guard let changes = await self?.store.changes() else { return }
      for await _ in changes { await self?.closeForReload() }
    }
  }

  private func closeForReload() {
    guard opening != nil else { return }
    exit()
  }

  func changes() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    listeners[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeListener(id) }
    }
    return stream
  }

  private func removeListener(_ id: UUID) {
    listeners[id] = nil
  }

  // MARK: - Opening and closing

  func open() async throws(AtelierError) -> Outcome {
    if opening != nil {
      opening?.keys.withLock { $0.path = [] }
      restartTimeout()
      await refreshMenu()
      return .changed
    }
    guard mac.hasAccessibility else { throw .accessibilityRequired }
    generation += 1
    let generation = generation
    guard let display = await workspace.keyboardDisplay() else { throw .unavailable }
    let configuration = await store.current
    let keys = SharedKeys(Keys(root: configuration.menu, leaderChord: configuration.leader.chord))
    guard let (listener, acts) = try await listen(keys, generation: generation) else {
      return .unchanged
    }
    var opening = Opening(
      generation: generation, configuration: configuration, display: display.id, keys: keys,
      listener: listener, acts: acts, isShown: configuration.leader.delay == .zero)
    if !opening.isShown {
      opening.delay = Task { [weak self] in
        try? await Task.sleep(for: configuration.leader.delay)
        guard !Task.isCancelled else { return }
        await self?.show(generation: generation)
      }
    }
    self.opening = opening
    restartTimeout()
    await refreshMenu()
    return .changed
  }

  /// Closes the menu. Anything still under way for it, an opening included,
  /// finds the generation moved on and stops.
  func exit() {
    generation += 1
    guard var opening else { return }
    self.opening = nil
    opening.listener?.stop()
    opening.listener = nil
    opening.acts?.finish()
    opening.delay?.cancel()
    opening.timeout?.cancel()
    opening.feedbackTimer?.cancel()
    state = nil
    announce()
  }

  /// Starts a listener whose acts this session handles for `generation`,
  /// reading them until the returned continuation is finished. Nil, with
  /// the listener already stopped, when the generation moved on meanwhile.
  private func listen(_ keys: SharedKeys, generation: Int) async throws(AtelierError)
    -> (any KeyListening, AsyncStream<Act>.Continuation)?
  {
    let (acts, continuation) = AsyncStream.makeStream(of: Act.self)
    let decide = Self.decider(keys: keys, acts: continuation)
    guard let listener = await mac.listenToKeys(decide) else {
      throw .failed(
        "Atelier could not listen to the keyboard. Check its Accessibility permission.")
    }
    guard self.generation == generation else {
      listener.stop()
      continuation.finish()
      return nil
    }
    Task { [weak self] in
      for await act in acts {
        guard let self else { return }
        await self.handle(act, generation: generation)
      }
    }
    return (listener, continuation)
  }

  private func restartTimeout() {
    guard let timeout = opening?.configuration.leader.timeout, let generation = opening?.generation
    else { return }
    opening?.timeout?.cancel()
    opening?.timeout = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      await self?.timedOut(generation: generation)
    }
  }

  private func timedOut(generation: Int) {
    guard opening?.generation == generation else { return }
    exit()
  }

  private func show(generation: Int) {
    guard opening?.generation == generation else { return }
    opening?.isShown = true
    publish()
  }

  // MARK: - Deciding, on the listener's thread

  /// The decision for each event is made here at once; anything that takes
  /// time, drawing or running a command, is asked of the session afterwards.
  private static func decider(keys: SharedKeys, acts: AsyncStream<Act>.Continuation)
    -> @Sendable (KeyEvent) -> KeyDecision
  {
    { event in
      keys.withLock { keys in
        switch event {
        case .flagsChanged(let modifiers):
          if keys.heldLeader, let leader = keys.leaderChord,
            leader.modifiers.isDisjoint(with: modifiers)
          {
            keys.heldLeader = false
          }
          return .pass
        case .mouseDown, .appSwitched:
          acts.yield(.exit)
          return .pass
        case .keyDown(let raw):
          if raw.modifiers.contains(.command), raw.key == "tab" {
            acts.yield(.exit)
            return .pass
          }
          acts.yield(.activity)
          if raw == keys.leaderChord {
            keys.path = []
            acts.yield(.render)
            return .consume
          }
          // A key without the leader's modifiers proves they were released,
          // whether or not the release itself was seen.
          if keys.heldLeader, let leader = keys.leaderChord,
            leader.modifiers.isDisjoint(with: raw.modifiers)
          {
            keys.heldLeader = false
          }
          let pressed =
            keys.heldLeader && keys.leaderChord != nil
            ? Chord(raw.modifiers.subtracting(keys.leaderChord!.modifiers), raw.key) : raw
          if pressed == Chord([], "escape") {
            acts.yield(.exit)
            return .consume
          }
          if pressed == Chord([], "delete") {
            if !keys.path.isEmpty { keys.path.removeLast() }
            acts.yield(.render)
            return .consume
          }
          guard let entry = keys.menu.entries.first(where: { $0.chord == pressed }) else {
            acts.yield(
              .explain(
                raw.key.isEmpty ? "Unknown key" : "No command for \(KeyGrammar.describe(pressed))"))
            return .consume
          }
          switch entry {
          case .submenu:
            keys.path.append(pressed)
            acts.yield(.render)
          case .command(_, let command):
            acts.yield(.run(command))
          }
          return .consume
        }
      }
    }
  }

  private func handle(_ act: Act, generation: Int) async {
    guard opening?.generation == generation else { return }
    switch act {
    case .activity: restartTimeout()
    case .render: await refreshMenu()
    case .explain(let text): explain(text)
    case .exit: exit()
    case .run(let command): await run(command, generation: generation)
    }
  }

  // MARK: - Running and explaining

  /// The listener and every clock are off while the command runs, so
  /// keystrokes the command posts reach macOS and nothing closes or reveals
  /// the menu meanwhile; the menu is hidden, so a Desktop switch does not
  /// carry it along. Feedback that keeps the menu open turns them back on.
  /// This runs in the reader of the listener's acts, which ends after it;
  /// the command is never cancelled from here.
  private func run(_ command: Command, generation: Int) async {
    guard var opening else { return }
    opening.listener?.stop()
    opening.listener = nil
    opening.acts?.finish()
    opening.delay?.cancel()
    opening.timeout?.cancel()
    opening.feedbackTimer?.cancel()
    opening.isShown = false
    self.opening = opening
    publish()
    let failure: String?
    do {
      _ = try await runner.perform(command)
      failure = nil
    } catch {
      failure = error.message
    }
    guard self.opening?.generation == generation else { return }
    guard let failure else {
      exit()
      return
    }
    guard let (listener, acts) = try? await listen(opening.keys, generation: generation) else {
      exit()
      return
    }
    self.opening?.listener = listener
    self.opening?.acts = acts
    restartTimeout()
    explain(failure)
  }

  /// Shows a word in the footer for a moment, revealing the menu if the
  /// delay has not passed yet.
  private func explain(_ text: String) {
    guard var opening else { return }
    opening.delay?.cancel()
    opening.feedbackTimer?.cancel()
    opening.feedback = text
    opening.isShown = true
    let generation = opening.generation
    opening.feedbackTimer = Task { [weak self] in
      try? await Task.sleep(for: feedbackTime)
      guard !Task.isCancelled else { return }
      await self?.clearFeedback(generation: generation)
    }
    self.opening = opening
    publish()
  }

  private func clearFeedback(generation: Int) {
    guard opening?.generation == generation else { return }
    opening?.feedback = nil
    publish()
  }

  // MARK: - The menu and its state

  /// Reads what the current menu's commands need, availability and hints,
  /// and publishes. The Window menu is read once for all the arrangements,
  /// and only when the menu shows any.
  private func refreshMenu() async {
    guard var opening else { return }
    opening.refreshes += 1
    let refresh = opening.refreshes
    self.opening = opening
    let (path, menu) = opening.keys.withLock { ($0.path, $0.menu) }
    let configuration = opening.configuration
    let commands = menu.entries.compactMap { entry -> Command? in
      if case .command(_, let command) = entry { return command }
      return nil
    }
    let arrangements: [String: ArrangementInfo] =
      commands.contains(where: { if case .windowsArrange = $0 { true } else { false } })
      ? Dictionary(
        uniqueKeysWithValues: ((try? await workspace.arrangements()) ?? []).map { ($0.id, $0) })
      : [:]
    let desktops =
      commands.contains(where: { if case .desktopsSelect = $0 { true } else { false } })
      ? mac.spaces().first { $0.id == opening.display }?.desktops.count ?? 0 : 0
    // A slow read must not overwrite the answer to a later one.
    guard self.opening?.generation == opening.generation, self.opening?.refreshes == refresh
    else { return }
    let shortcuts = Dictionary(grouping: configuration.global, by: \.value)
      .mapValues { $0.map { KeyGrammar.describe($0.key) }.sorted() }
    self.opening?.entries = menu.entries.compactMap { entry -> LeaderEntry? in
      switch entry {
      case .submenu(let chord, let submenu):
        return LeaderEntry(
          key: KeyGrammar.describe(chord), label: submenu.label, isSubmenu: true, hint: nil,
          unavailable: nil)
      case .command(let chord, let command):
        var hint = shortcuts[command]?.first
        var unavailable: String?
        var label = command.label
        switch command {
        case .windowsArrange(let arrangement):
          if let info = arrangements[arrangement.rawValue] {
            unavailable = info.unavailable
            hint = hint ?? info.shortcut
          } else {
            unavailable = "The Window menu could not be read."
          }
        case .desktopsSelect(let number):
          // A Desktop that does not exist is left out rather than dimmed.
          guard number <= desktops else { return nil }
        case .quickAppsToggle(let app):
          // By the name on disk, not the bundle identifier or path configured.
          if let found = mac.findApp(app) {
            label = found.name
          } else {
            unavailable = QuickApps.notFound(app)
          }
        default: break
        }
        return LeaderEntry(
          key: KeyGrammar.describe(chord), label: label, isSubmenu: false, hint: hint,
          unavailable: unavailable)
      }
    }
    self.opening?.title =
      path.isEmpty
      ? configuration.menu.label
      : path.indices.map { Keys.menu(configuration.menu, at: Array(path[...$0])).label }
        .joined(separator: " › ")
    publish()
  }

  private func publish() {
    guard let opening else { return }
    state = LeaderState(
      title: opening.title, entries: opening.entries, feedback: opening.feedback,
      display: opening.display, isShown: opening.isShown)
    announce()
  }

  private func announce() {
    for listener in listeners.values { listener.yield() }
  }
}
