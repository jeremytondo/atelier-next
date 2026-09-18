import Foundation
import MacOS

/// The `config` subject: the file at `~/.config/atelier/config-next.toml`, what is
/// in effect, and reloading. Atelier reads the file when it starts and when
/// asked, never on its own; a file that cannot be read leaves the last good
/// configuration in effect, or the defaults at startup, with the problem on
/// record until a reload succeeds.
public struct Config: Sendable {
  let store: ConfigStore
  /// The file being read and put into effect at startup. Every question
  /// waits for it, so nothing sees the moment before the file applied.
  private let installation: Task<Void, Never>

  init(store: ConfigStore, installation: Task<Void, Never>) {
    self.store = store
    self.installation = installation
  }

  /// `config show`: what is in effect.
  public func show() async -> ConfigReport {
    await installation.value
    return await store.report()
  }

  /// `config check`: what the file says now, without applying it.
  public func check() async -> ConfigReport {
    await installation.value
    return await store.check()
  }

  /// `config open`: opens the file in the app the user has for it, writing a
  /// commented starting point first when there is none.
  public func open() async throws(AtelierError) -> Outcome {
    await installation.value
    return try await store.open()
  }

  /// `config reload`: reads the file and puts it into effect, every binding
  /// at once. Fails, changing nothing, when the file cannot be read.
  public func reload() async throws(AtelierError) -> ReloadResult {
    await installation.value
    return try await store.reload()
  }

  /// The theme in effect.
  public func theme() async -> Theme {
    await installation.value
    return await store.current.theme
  }

  /// The problems in effect, until a reload without them.
  public func problems() async -> [Problem] {
    await installation.value
    return await store.problems
  }

  /// Yields after the configuration in effect, or its problems, changed.
  public func changes() async -> AsyncStream<Void> {
    await installation.value
    return await store.changes()
  }

  /// Waits for the configuration read at startup to be in effect.
  package func ready() async {
    await installation.value
  }
}

public struct ReloadResult: Equatable, Sendable {
  public let outcome: Outcome
  public let problems: [Problem]
}

/// The configuration and its bindings are replaced together: the shortcuts
/// registered with macOS are always exactly those of `current`.
actor ConfigStore {
  let mac: any Mac
  let file: URL?
  private(set) var current: Configuration
  /// Why the file was last refused, until a reload reads it.
  private(set) var rejection: Problem?
  /// While a configuration is being put into effect; a second reload then
  /// would interleave with it.
  private var isApplying = false
  private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]

  init(mac: any Mac, file: URL?) {
    self.mac = mac
    self.file = file
    current = Keymap.resolve(Overrides(), spaceShortcuts: [])
  }

  var problems: [Problem] {
    current.problems + (rejection.map { [$0] } ?? [])
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

  /// Puts the file into effect at startup; the defaults when it is refused.
  func start() async {
    let loaded = await load()
    rejection = loaded.rejection
    await apply(loaded.configuration)
  }

  func report() -> ConfigReport {
    ConfigReport(file: file, configuration: current, rejection: rejection)
  }

  func check() async -> ConfigReport {
    let loaded = await load()
    return ConfigReport(
      file: file, configuration: loaded.configuration, rejection: loaded.rejection)
  }

  func reload() async throws(AtelierError) -> ReloadResult {
    guard !isApplying else { throw .busy }
    let loaded = await load()
    if let rejection = loaded.rejection {
      self.rejection = rejection
      announce()
      throw .failed(
        "The configuration was not reloaded, so the previous one stays in effect. \(rejection.text)"
      )
    }
    let before = (current, rejection)
    rejection = nil
    await apply(loaded.configuration)
    return ReloadResult(
      outcome: before == (current, rejection) ? .unchanged : .changed, problems: current.problems)
  }

  func open() throws(AtelierError) -> Outcome {
    guard let file else { throw .unsupported("This Atelier has no configuration file.") }
    if !FileManager.default.fileExists(atPath: file.path) {
      do {
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Defaults.fileTemplate.write(to: file, atomically: true, encoding: .utf8)
      } catch {
        throw .failed("Could not create \(file.path): \(error.localizedDescription)")
      }
    }
    guard mac.open(file) else { throw .failed("macOS could not open \(file.path).") }
    return .changed
  }

  private struct Loaded {
    var configuration: Configuration
    var rejection: Problem?
  }

  /// Reads and resolves the file. No file is the defaults; a file that
  /// cannot be read or parsed is the defaults with the rejection.
  private func load() async -> Loaded {
    let spaceShortcuts = Set(await mac.spaceSwitchingChords())
    let defaults = Keymap.resolve(Overrides(), spaceShortcuts: spaceShortcuts)
    guard let file, FileManager.default.fileExists(atPath: file.path) else {
      return Loaded(configuration: defaults)
    }
    let text: String
    do {
      text = try String(contentsOf: file, encoding: .utf8)
    } catch {
      return Loaded(
        configuration: defaults,
        rejection: Problem(
          location: "file", message: "could not be read: \(error.localizedDescription)"))
    }
    switch Overrides.parse(text) {
    case .success(let overrides):
      return Loaded(configuration: Keymap.resolve(overrides, spaceShortcuts: spaceShortcuts))
    case .failure(let problem):
      return Loaded(configuration: defaults, rejection: problem)
    }
  }

  /// Registers the configuration's shortcuts in place of the current ones. A
  /// shortcut macOS refuses is left out, with the reason on record. The new
  /// configuration is current before macOS is asked, so a press that arrives
  /// while the shortcuts change runs the new command for its chord or nothing.
  private func apply(_ configuration: Configuration) async {
    isApplying = true
    defer { isApplying = false }
    current = configuration
    let chords = Array(configuration.global.keys) + (configuration.leader.chord.map { [$0] } ?? [])
    let refused = await mac.registerHotKeys(chords)
    for (chord, reason) in refused.sorted(by: { KeyGrammar.text($0.key) < KeyGrammar.text($1.key) })
    {
      if chord == current.leader.chord {
        current.problems.append(Problem(location: "leader key", message: reason))
        current.leader.chord = nil
      } else {
        current.problems.append(
          Problem(location: "shortcut \(KeyGrammar.describe(chord))", message: reason))
        current.global[chord] = nil
      }
    }
    announce()
  }

  private func announce() {
    for listener in listeners.values { listener.yield() }
  }
}
