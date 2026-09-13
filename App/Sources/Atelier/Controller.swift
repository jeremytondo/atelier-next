import AppKit
import AtelierCore
import NativeMenuDispatch
import QuickAppSupport

@MainActor
final class Controller: ObservableObject {
  @Published private(set) var state = "Paused"
  @Published private(set) var lastError: String?
  @Published private(set) var quickErrors: [UUID: String] = [:]
  @Published private(set) var quickNames: [UUID: String] = [:]
  @Published private(set) var accessibility = AXIsProcessTrusted()
  @Published private(set) var reloading = false
  @Published private(set) var configurationError: String?
  let settings: ConfigurationStore
  let diagnostics = Diagnostics()
  private let engine = EngineClient()
  private let hotkeys = Hotkeys()
  private let overlay = GroupOverlay()
  private let observers = WindowObservers()
  private var windows: WindowAccess?
  private(set) var store = GroupStore()
  private(set) var snapshot: Snapshot?
  private var gate = OperationGate()
  private var quickBundleIDs: [UUID: String] = [:]
  private var activeConfiguration = AppConfiguration()
  private var filled: [WindowKey: WindowFrame] = [:]
  private var fillFailed: Set<WindowKey> = []
  private var settling: [WindowKey: Task<Void, Never>] = [:]
  private var geometry: [Int32: Double] = [:]
  private var observedFocus: WindowKey?
  private var observing = false
  private var observedEpoch: UInt64 = 0
  private var poll: Timer?
  private var refreshJob: Task<Void, Never>?
  private var work: Task<Void, Never>?
  private var lifecycle: [NSObjectProtocol] = []
  private var resumeAfterWake = false
  var changed: (() -> Void)?
  var running: Bool { state == "Running" }
  var helperPID: Int32? { engine.pid }
  init(settings: ConfigurationStore) {
    self.settings = settings
    engine.onFailure = { [weak self] message in
      self?.pause()
      self?.state = "Engine stopped"
      self?.report(message)
    }
    engine.record = { [weak self] name, ms in self?.diagnostics.record(name, ms: ms) }
    hotkeys.onCommand = { [weak self] command in self?.perform(command) }
    overlay.current = { [weak self] in
      guard let self, let snapshot = self.snapshot else { return (nil, nil, false) }
      return (self.store.current(snapshot), self.windows?.focusedKey(), snapshot.missionControl)
    }
    overlay.onChord = { [weak self] in self?.observe() }
    observers.changed = { [weak self] pid, event in
      guard let self, self.running else { return }
      if event == kAXMovedNotification || event == kAXResizedNotification {
        self.geometry[pid] = ProcessInfo.processInfo.systemUptime
      }
      self.overlay.redraw()
      self.scheduleObserve()
    }
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
      NSWorkspace.didUnhideApplicationNotification,
    ] {
      lifecycle.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.scheduleObserve() }
        })
    }
    lifecycle.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.resumeAfterWake = self.running
          self.pause()
        }
      })
    lifecycle.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          guard let self, self.resumeAfterWake else { return }
          self.resumeAfterWake = false
          try? await Task.sleep(for: .seconds(1))
          await self.start()
        }
      })
    lifecycle.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in Task { @MainActor in self?.scheduleObserve() } })
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.accessibility = AXIsProcessTrusted()
        if self.running && !self.accessibility {
          self.pause()
          self.state = "Accessibility needed"
          self.report("Accessibility access was removed. Grant access and press Resume.")
        }
        self.observe()
        self.writeStatus()
      }
    }
    poll = timer
    RunLoop.main.add(timer, forMode: .common)
    activeConfiguration = settings.configuration
    installReloadShortcut()
  }
  func start() async {
    guard state != "Starting", !running, !reloading else { return }
    accessibility = AXIsProcessTrusted()
    guard accessibility else {
      state = "Accessibility needed"
      changed?()
      return
    }
    guard !settings.loadFailed else {
      report("Fix config.toml and choose Reload Configuration before resuming Atelier.")
      return
    }
    state = "Starting"
    lastError = nil
    gate.invalidate()
    let epoch = gate.generation
    activeConfiguration = settings.configuration
    changed?()
    do {
      if windows == nil { windows = try WindowAccess() }
      try await engine.start()
      guard gate.generation == epoch else { return }
      hotkeys.stop()
      try hotkeys.start()
      for binding in try Hotkeys.defaults(activeConfiguration) { try hotkeys.add(binding) }
      quickBundleIDs.removeAll()
      quickErrors.removeAll()
      quickNames.removeAll()
      var seen: Set<String> = []
      for app in activeConfiguration.quickApps where app.enabled {
        guard gate.generation == epoch else { return }
        do {
          var request = EngineRequest("quickResolve")
          request.app = app.app
          let resolved: ResolvedApplication = try await engine.request(request)
          guard gate.generation == epoch else { throw CancellationError() }
          guard seen.insert(resolved.bundleID).inserted else {
            throw AppError("This application is already configured as a Quick App.")
          }
          quickNames[app.id] = resolved.name
          // Exclude configured apps even if their shortcut cannot register.
          quickBundleIDs[app.id] = resolved.bundleID
          try hotkeys.add(.init(shortcut: app.shortcut, command: .quick(app.id)))
          diagnostics.record(
            "quickApp:configured", detail: "\(resolved.bundleID) · \(app.shortcut.label)")
        } catch {
          guard gate.generation == epoch else { return }
          quickErrors[app.id] = error.localizedDescription
          diagnostics.record(
            "quickApp:invalid", detail: "\(app.app): \(error.localizedDescription)")
        }
      }
      guard gate.generation == epoch else { return }
      _ = try await refresh(epoch: epoch)
      state = "Running"
      configureOverlay()
      settings.applyLoginPreference()
      diagnostics.record("started")
      changed?()
      writeStatus()
    } catch {
      guard gate.generation == epoch else { return }
      pause()
      state = "Could not start"
      report(error.localizedDescription)
    }
  }
  func pause() {
    gate.invalidate()
    work?.cancel()
    work = nil
    refreshJob?.cancel()
    refreshJob = nil
    hotkeys.stop()
    observers.stop()
    overlay.stop()
    for task in settling.values { task.cancel() }
    settling.removeAll()
    geometry.removeAll()
    observing = false
    engine.stop()
    observedFocus = nil
    state = "Paused"
    installReloadShortcut()
    diagnostics.record("paused")
    changed?()
    writeStatus()
  }
  func shutdown() {
    pause()
    hotkeys.stop()
    poll?.invalidate()
    poll = nil
  }
  func report(_ message: String) {
    lastError = message
    diagnostics.record("error", detail: message)
    changed?()
    writeStatus()
  }
  func requestAccessibility() {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }
  @discardableResult private func refresh(epoch: UInt64) async throws -> Snapshot {
    var result: Snapshot = try await engine.request(EngineRequest("snapshot"))
    guard gate.generation == epoch else { throw CancellationError() }
    guard result.trusted else {
      throw AppError("The engine needs Accessibility access through Atelier.")
    }
    guard !result.displays.isEmpty else {
      throw AppError(
        "macOS returned no Desktop topology. Pause and retry after Mission Control finishes.")
    }
    result.exclude(
      Set(quickBundleIDs.values).union([
        Bundle.main.bundleIdentifier ?? "com.elevenideas.Atelier"
      ]))
    snapshot = result
    store.reconcile(result)
    let live = Set(store.groups.values.flatMap { $0.members.map(\.key) })
    filled = filled.filter { live.contains($0.key) }
    fillFailed.formIntersection(live)
    if let windows, activeConfiguration.groups { observers.sync(result.windows, access: windows) }
    overlay.redraw()
    return result
  }
  func perform(_ command: Command) {
    if command == .reload {
      Task { await reloadConfiguration() }
      return
    }
    guard running, !reloading else { return }
    guard let epoch = gate.begin(command.name) else {
      diagnostics.record("dropped:\(command.name)", detail: "busy: \(gate.active ?? "operation")")
      return
    }
    work = Task {
      let began = ProcessInfo.processInfo.systemUptime
      defer {
        gate.end(epoch)
        diagnostics.record(
          "action:\(command.name)", ms: (ProcessInfo.processInfo.systemUptime - began) * 1000)
        writeStatus()
      }
      do {
        let s = try await refresh(epoch: epoch)
        try Task.checkCancellation()
        guard running, gate.generation == epoch else { return }
        switch command {
        case .group:
          let group = try store.group(s)
          for member in group.members { fillFailed.remove(member.key) }
          if let member = group.members.first(where: { $0.id == s.focused }) ?? group.members.first
          {
            try await activate(member, group: group, epoch: epoch)
          }
        case .select(let number):
          if let group = store.current(s), group.members.indices.contains(number - 1) {
            try await activate(group.members[number - 1], group: group, epoch: epoch)
          }
        case .cycle(let offset):
          if let group = store.current(s), !group.members.isEmpty {
            let index = group.members.firstIndex(where: { $0.id == s.focused }) ?? -1
            let next =
              ((index + offset) % group.members.count + group.members.count) % group.members.count
            try await activate(group.members[next], group: group, epoch: epoch)
          }
        case .quick(let id):
          guard
            let entry = activeConfiguration.quickApps.first(where: { $0.id == id && $0.enabled }),
            let bundleID = quickBundleIDs[id], quickErrors[id] == nil
          else {
            throw AppError("Fix this Quick App in config.toml and reload before toggling it.")
          }
          var request = EngineRequest("quickToggle")
          request.app = entry.app
          request.expectedBundleID = bundleID
          request.size = entry.size
          let _: EmptyResult = try await engine.request(request)
          _ = try await refresh(epoch: epoch)
        default:
          guard let display = s.target else { throw AppError("The target display is unavailable.") }
          var request = EngineRequest(command.name)
          request.display = display.id
          request.current = display.current
          switch command {
          case .desktop(let n): request.number = n
          case .reorder(let n): request.offset = n
          default: break
          }
          hotkeys.suspendSpaces()
          do {
            let _: EmptyResult = try await engine.request(request)
            if running, gate.generation == epoch { try hotkeys.resumeSpaces() }
          } catch {
            if running, gate.generation == epoch { try hotkeys.resumeSpaces() }
            throw error
          }
          _ = try await refresh(epoch: epoch)
        }
      } catch is CancellationError {} catch {
        if gate.generation == epoch { report(error.localizedDescription) }
      }
    }
  }
  private func activate(_ member: WindowRecord, group: WindowGroup, epoch: UInt64) async throws {
    guard let windows else { return }
    let began = ProcessInfo.processInfo.systemUptime
    let element = try await windows.focus(
      member, group: group.key,
      valid: { self.running && self.gate.generation == epoch && !Task.isCancelled })
    diagnostics.record("focus", ms: (ProcessInfo.processInfo.systemUptime - began) * 1000)
    overlay.redraw()
    try fill(member, element: element, group: group.key, epoch: epoch)
  }
  private func fill(_ member: WindowRecord, element: AXUIElement, group: GroupKey, epoch: UInt64)
    throws
  {
    guard let windows, settling[member.key] == nil, !fillFailed.contains(member.key),
      windows.focusedKey() == member.key,
      windows.isCurrent(group), windows.belongs(member.key, to: group.space),
      let initial = windows.frame(element), !initial.matches(filled[member.key])
    else { return }
    let began = ProcessInfo.processInfo.systemUptime
    do {
      _ = try NativeMenuDispatcher.dispatch(
        identifier: "_zoomFill:", commandName: "Fill", processID: member.pid, window: element)
    } catch {
      fillFailed.insert(member.key)
      throw error
    }
    diagnostics.record("fill:press", ms: (ProcessInfo.processInfo.systemUptime - began) * 1000)
    var settlement = FillSettlement(frame: initial, now: began)
    settling[member.key] = Task { [weak self] in
      guard let self else { return }
      defer { if self.gate.generation == epoch { self.settling.removeValue(forKey: member.key) } }
      do {
        while ProcessInfo.processInfo.systemUptime - began < 3 {
          try await Task.sleep(for: .milliseconds(20))
          guard self.running, self.gate.generation == epoch else { return }
          guard let frame = windows.frame(element) else {
            throw AppError("The window disappeared while Fill was settling.")
          }
          if settlement.sample(
            frame, eventAt: self.geometry[member.pid] ?? 0,
            now: ProcessInfo.processInfo.systemUptime)
          {
            self.filled[member.key] = frame
            self.diagnostics.record(
              "fill:settled", ms: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            return
          }
        }
        throw AppError("Native Fill did not settle in \(member.app). Repair the Group to retry.")
      } catch is CancellationError {} catch {
        if self.gate.generation == epoch {
          self.fillFailed.insert(member.key)
          self.report(error.localizedDescription)
        }
      }
    }
  }
  private func scheduleObserve() {
    guard running, refreshJob == nil else { return }
    refreshJob = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(25))
      guard !Task.isCancelled else { return }
      self?.refreshJob = nil
      self?.observe()
    }
  }
  func observe() {
    guard running, !reloading, gate.active == nil, !observing else { return }
    observing = true
    let epoch = gate.generation
    observedEpoch = epoch
    Task {
      defer { if observedEpoch == epoch { observing = false } }
      do {
        let s = try await refresh(epoch: epoch)
        guard running, gate.generation == epoch, gate.active == nil, activeConfiguration.groups,
          let windows
        else { return }
        let group = store.current(s)
        let member = group?.members.first { $0.id == s.focused }
        if let member, let group, windows.focusedKey() == member.key, member.key != observedFocus,
          let element = windows.element(member.key)
        {
          try fill(member, element: element, group: group.key, epoch: epoch)
        }
        observedFocus = member?.key
      } catch is CancellationError {} catch {
        if gate.generation == epoch { report(error.localizedDescription) }
      }
    }
  }
  func exportDiagnostics() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Atelier-diagnostics.json"
    panel.allowedContentTypes = [.json]
    if panel.runModal() == .OK, let url = panel.url {
      do { try diagnosticData().write(to: url, options: .atomic) } catch {
        report(error.localizedDescription)
      }
    }
  }
  func diagnosticData() throws -> Data {
    let data = try diagnostics.data(
      state: state, error: lastError, snapshot: snapshot, groups: Array(store.groups.values),
      helperPID: helperPID)
    var value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    value["configuration"] = [
      "path": settings.url.path, "files": settings.files.map(\.path),
      "error": configurationError as Any? ?? NSNull(), "reloading": reloading,
      "bindings": (try? activeConfiguration.effectiveBindings().mapValues(\.configText)) ?? [:],
      "quickApps": activeConfiguration.quickApps.map {
        [
          "name": $0.configName ?? $0.app, "app": $0.app, "shortcut": $0.shortcut.configText,
          "enabled": $0.enabled,
        ] as [String: Any]
      },
      "overlay": activeConfiguration.overlay,
    ]
    return try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  }
  func diagnosticPerform(_ command: Command) async throws {
    guard running, gate.active == nil else { throw AppError("Atelier is paused or busy.") }
    lastError = nil
    perform(command)
    await work?.value
    if let lastError { throw AppError(lastError) }
  }
  private func writeStatus() {
    if let data = try? diagnosticData() {
      try? data.write(
        to: settings.stateDirectory.appendingPathComponent("status.json"), options: .atomic)
    }
  }

  private func installReloadShortcut() {
    do {
      try hotkeys.start()
      let bindings = try Hotkeys.defaults(settings.configuration).filter { $0.command == .reload }
      try hotkeys.replace(with: bindings)
    } catch {
      diagnostics.record("reload-shortcut:unavailable", detail: error.localizedDescription)
    }
  }

  private func configureOverlay() {
    overlay.stop()
    overlay.configure(activeConfiguration)
    if running && activeConfiguration.groups && activeConfiguration.overlay { overlay.start() }
  }

  /// No process restart, file write, or window mutation. Do not interrupt a
  /// Desktop operation; let its outcome settle before swapping bindings.
  func reloadConfiguration() async {
    guard !reloading else { return }
    reloading = true
    changed?()
    defer {
      reloading = false
      changed?()
      writeStatus()
    }
    do {
      guard state != "Starting" else {
        throw AppError("Atelier is starting. Reload when it is ready.")
      }
      let loaded = try settings.read()
      let epoch = gate.generation
      if running {
        await work?.value
        for _ in 0..<100 where observing {
          try await Task.sleep(for: .milliseconds(20))
        }
        guard running, gate.generation == epoch, gate.active == nil, !observing else {
          throw AppError(
            "Atelier's runtime changed or is still busy. Reload again when it is ready.")
        }
      }
      let candidate = loaded.configuration
      var names: [UUID: String] = [:]
      var bundleIDs: [UUID: String] = [:]
      var bindings = try Hotkeys.defaults(candidate)
      var seen: Set<String> = []
      for app in candidate.quickApps where app.enabled {
        do {
          let target = try TargetApplication.resolve(app.app)
          guard seen.insert(target.bundleIdentifier).inserted else {
            throw AppError("This application is already configured as a Quick App.")
          }
          names[app.id] = target.name
          bundleIDs[app.id] = target.bundleIdentifier
          bindings.append(.init(shortcut: app.shortcut, command: .quick(app.id)))
        } catch {
          throw AppError("quickapps.\(app.configName ?? app.app): \(error.localizedDescription)")
        }
      }
      try hotkeys.start()
      try hotkeys.replace(with: running ? bindings : bindings.filter { $0.command == .reload })
      // Everything that can reject this configuration has succeeded. The
      // remainder commits synchronously on the main actor.
      settings.accept(loaded)
      activeConfiguration = candidate
      quickNames = names
      quickBundleIDs = bundleIDs
      quickErrors.removeAll()
      configurationError = nil
      if !candidate.groups {
        observers.stop()
        for task in settling.values { task.cancel() }
        settling.removeAll()
      }
      configureOverlay()
      settings.applyLoginPreference()
      diagnostics.record("configuration:reloaded", detail: settings.url.path)
    } catch {
      configurationError = error.localizedDescription
      settings.reject(error)
      diagnostics.record("configuration:rejected", detail: error.localizedDescription)
    }
  }
}
