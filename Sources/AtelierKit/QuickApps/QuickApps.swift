import Foundation
import MacOS

/// One configured Quick App as it stands right now.
public struct QuickAppInfo: Equatable, Identifiable, Sendable {
  public var id: String { app }
  /// The app as configured: a name, bundle identifier, or path.
  public let app: String
  /// The app as found on disk, or nil with `problem` set.
  public let name: String?
  public let leader: String?
  public let shortcut: String?
  public let isShown: Bool
  /// Why the app cannot be summoned, when it cannot.
  public let problem: String?
}

/// The `quick-apps` subject: apps summoned to the current Desktop with one
/// key and hidden with the same key, a switch of focus, or a change of
/// Space. Configuring an app changes nothing about it; only summoning it
/// through Atelier gives it this behavior, and opening it normally again
/// takes the behavior away. One Quick App shows at a time.
public struct QuickApps: Sendable {
  let workspace: Workspace
  let config: ConfigStore

  /// `quick-apps list`
  public func list() async -> [QuickAppInfo] {
    let configuration = await config.current
    let shown = await workspace.quickApp.shown?.app
    return configuration.quickApps.map { settings in
      let found = workspace.mac.findApp(settings.app)
      return QuickAppInfo(
        app: settings.app, name: found?.name,
        leader: settings.leader.map(KeyGrammar.describe),
        shortcut: settings.shortcut.map(KeyGrammar.describe),
        isShown: found.flatMap(workspace.mac.runningApp).map { $0 == shown } ?? false,
        problem: found == nil ? Self.notFound(settings.app) : nil)
    }
  }

  /// `quick-apps toggle`: hides the app when it is the one shown, else
  /// summons it onto the Desktop with the keyboard, hiding any other Quick
  /// App first. The app is named as in the configuration.
  public func toggle(_ app: String) async throws(AtelierError) -> Outcome {
    guard let settings = await config.current.quickApps.first(where: { $0.app == app }) else {
      throw .failed("No Quick App is configured as \"\(app)\". Add it under [[quick-apps]].")
    }
    guard let found = workspace.mac.findApp(settings.app) else {
      throw .failed(Self.notFound(settings.app))
    }
    return try await workspace.toggleQuickApp(found, size: settings.size)
  }

  static func notFound(_ app: String) -> String {
    "No app named \"\(app)\" was found. Give a name, bundle identifier, or path."
  }
}

/// Which apps are under Quick App behavior, and which one is showing.
struct QuickAppState: Sendable {
  struct Shown: Sendable {
    let app: Int32
    let space: UInt64
  }

  var shown: Shown?
  /// Apps summoned through Atelier and not opened normally since, shown or
  /// hidden. Their windows stay out of the window lists.
  var summoned: Set<Int32> = []
  /// The app being summoned right now, whose coming to the front is Atelier's doing.
  var summoning: Int32?
  /// The window last shown for each app, to show it again.
  var lastWindow: [Int32: UInt32] = [:]
}

/// How a Quick App window is placed: centered in the display's usable area,
/// kept as it is when smaller, else held to a floating size.
enum QuickAppPlacement {
  static let defaultMaximum = CGSize(width: 1000, height: 720)
  static let displayFraction = 0.8
  static let inset: CGFloat = 8

  /// The frame to ask for, from the window's frame now and the usable area.
  static func frame(for current: CGRect, in usable: CGRect, size: QuickAppSettings.Size?) -> CGRect
  {
    let usable = usable.insetBy(dx: inset, dy: inset)
    let maximum =
      size.map { _ in usable.size }
      ?? CGSize(
        width: min(defaultMaximum.width, (usable.width * displayFraction).rounded(.down)),
        height: min(defaultMaximum.height, (usable.height * displayFraction).rounded(.down)))
    let wanted = CGSize(
      width: min(size.map { CGFloat($0.width) } ?? current.width, maximum.width),
      height: min(size.map { CGFloat($0.height) } ?? current.height, maximum.height))
    return centered(wanted, in: usable)
  }

  static func centered(_ size: CGSize, in usable: CGRect) -> CGRect {
    CGRect(
      x: usable.midX - size.width / 2, y: usable.midY - size.height / 2, width: size.width,
      height: size.height)
  }
}

extension Workspace {
  func toggleQuickApp(_ app: AppReference, size: QuickAppSettings.Size?) async throws(AtelierError)
    -> Outcome
  {
    try await run { observation async throws(AtelierError) in
      if let pid = mac.runningApp(app), quickApp.shown?.app == pid {
        try await hideQuickApp(pid, name: app.name)
        return .changed
      }
      guard observation.space.isDesktop else {
        throw .failed("Quick Apps appear on Desktops; leave the full-screen or Split View Space.")
      }
      let origin = (display: observation.display.id, space: observation.space.id)
      // The window is found, launching if need be, before the Quick App
      // showing now is hidden, so a launch that fails leaves it as it was.
      let (pid, window, brought) = try await findWindow(of: app, in: observation.snapshot)
      if let other = quickApp.shown, other.app != pid {
        let name =
          observation.snapshot.windows.first { $0.app == other.app }?.appName ?? "the other"
        try await hideQuickApp(other.app, name: name + " Quick App")
      }
      quickApp.summoning = pid
      defer { quickApp.summoning = nil }
      do throws(AtelierError) {
        try await present(window, of: pid, name: app.name, size: size, at: origin)
      } catch {
        // What Atelier brought out it puts away again; an app the user had
        // out stays out.
        if brought { _ = mac.setAppHidden(pid, true) }
        throw error
      }
      quickApp.shown = QuickAppState.Shown(app: pid, space: origin.space)
      quickApp.summoned.insert(pid)
      quickApp.lastWindow[pid] = window
      return .changed
    }
  }

  /// Hides every window of the app and confirms it before Atelier counts it
  /// hidden. No focus is restored: macOS gives the keyboard to whatever is next.
  private func hideQuickApp(_ pid: Int32, name: String) async throws(AtelierError) {
    guard mac.setAppHidden(pid, true) else { throw .failed("\(name) is not running.") }
    guard await wait(patience.focus, until: { mac.isAppHidden(pid) == true }) else {
      throw .failed("Could not hide \(name).")
    }
    if quickApp.shown?.app == pid { quickApp.shown = nil }
  }

  /// An ordinary window of the app, front to back, launching the app and
  /// waiting for one when it has none, and whether Atelier brought the app
  /// out: it was not running, or was hidden. A launched app is under
  /// Atelier's hand from then on, so its coming to the front is not a normal
  /// opening.
  private func findWindow(of app: AppReference, in snapshot: Snapshot) async throws(AtelierError)
    -> (Int32, UInt32, brought: Bool)
  {
    let running = mac.runningApp(app)
    let brought = running.map { mac.isAppHidden($0) == true } ?? true
    if let pid = running, let window = eligibleWindow(of: pid, in: snapshot) {
      return (pid, window, brought)
    }
    guard let pid = await mac.launch(app) else { throw .failed("\(app.name) would not launch.") }
    quickApp.summoning = pid
    defer { quickApp.summoning = nil }
    var window: UInt32?
    let found = await wait(patience.launch) {
      if let snapshot = await mac.snapshot() { window = eligibleWindow(of: pid, in: snapshot) }
      return window != nil
    }
    guard found, let window else { throw .failed("\(app.name) did not open a window in time.") }
    return (pid, window, brought)
  }

  /// The window last shown, else the frontmost ordinary one.
  private func eligibleWindow(of pid: Int32, in snapshot: Snapshot) -> UInt32? {
    let windows = snapshot.windows.filter { $0.app == pid && $0.report == .ordinary }
    if let last = quickApp.lastWindow[pid], windows.contains(where: { $0.id == last }) {
      return last
    }
    return windows.first?.id
  }

  /// Puts the window on the origin Desktop, centered, and gives it the
  /// keyboard, checking at each step that the origin is still current.
  private func present(
    _ window: UInt32, of pid: Int32, name: String, size: QuickAppSettings.Size?,
    at origin: (display: String, space: UInt64)
  ) async throws(AtelierError) {
    func stillThere() throws(AtelierError) {
      guard mac.spaces().first(where: { $0.id == origin.display })?.currentSpace == origin.space
      else { throw .targetChanged("The Desktop changed, so \(name) was not shown.") }
    }
    try stillThere()
    if mac.isAppHidden(pid) == true { _ = mac.setAppHidden(pid, false) }
    // A window just made has no membership for a moment; one that never
    // reports any is taken to be where it was made, on the current Desktop.
    // A window on this Desktop among others, as one assigned to every
    // Desktop is, is here already and is left as it is.
    _ = await wait(patience.confirmation) { !mac.spaces(ofWindow: window).isEmpty }
    let membership = mac.spaces(ofWindow: window)
    if !membership.isEmpty, !membership.contains(origin.space) {
      let displays = mac.spaces()
      try check(
        await mac.moveWindow(window, toSpace: origin.space, expecting: displays), "moved",
        of: "Spaces")
      let arrived = await wait(patience.confirmation) {
        mac.spaces(ofWindow: window).contains(origin.space)
      }
      guard arrived else {
        throw .failed("macOS did not move the \(name) window to this Desktop.")
      }
    }
    try stillThere()
    guard let usable = await mac.usableFrame(ofDisplay: origin.display) else {
      throw .failed("The display is gone.")
    }
    guard let current = await mac.frame(ofWindow: window, in: pid) else {
      throw .failed("\(name) did not describe its window.")
    }
    let wanted = QuickAppPlacement.frame(for: current, in: usable, size: size)
    guard await mac.setFrame(wanted, ofWindow: window, in: pid) else {
      throw .failed("The \(name) window closed.")
    }
    // The app may keep its window larger than asked; it is centered as it is.
    guard var actual = await mac.frame(ofWindow: window, in: pid) else {
      throw .failed("\(name) did not describe its window.")
    }
    let inset = usable.insetBy(dx: QuickAppPlacement.inset, dy: QuickAppPlacement.inset)
    if actual.size != wanted.size {
      _ = await mac.setFrame(
        QuickAppPlacement.centered(actual.size, in: inset), ofWindow: window, in: pid)
      actual = await mac.frame(ofWindow: window, in: pid) ?? actual
    }
    // Asking proves nothing: the window is where it was asked to be, or not.
    let centered = QuickAppPlacement.centered(actual.size, in: inset)
    guard abs(actual.midX - centered.midX) < 2, abs(actual.midY - centered.midY) < 2 else {
      throw .failed("\(name) did not take its place on this display.")
    }
    try stillThere()
    switch await mac.raise(window: window, of: pid) {
    case .asked: break
    case .closed: throw .failed("The \(name) window closed.")
    case .unanswered: throw .failed("\(name) is not responding.")
    }
    let hasFocus = await wait(patience.focus) {
      let focus = await mac.focus()
      return focus.app == pid
        && (focus.window == window || focus.window != nil && !focus.windowIsOrdinary)
    }
    guard hasFocus else { throw .failed("Could not bring \(name) forward.") }
    try stillThere()
  }

  /// Runs on every hint from the Mac, busy or not: the shown Quick App hides
  /// when the keyboard leaves it or its Desktop stops being current, an app
  /// opened normally again stops being a Quick App, and one that quit is
  /// forgotten, so its process number cannot stand for another app later.
  func followQuickApps() async {
    for pid in quickApp.summoned where mac.isAppHidden(pid) == nil {
      quickApp.summoned.remove(pid)
      quickApp.lastWindow[pid] = nil
      if quickApp.shown?.app == pid { quickApp.shown = nil }
    }
    guard let shown = quickApp.shown else {
      guard !quickApp.summoned.isEmpty else { return }
      let focus = await mac.focus()
      // Frontmost while not shown by Atelier: the user opened it normally,
      // and the next census lists its windows again.
      if let app = focus.app, quickApp.summoned.contains(app), quickApp.shown == nil,
        quickApp.summoning != app
      {
        quickApp.summoned.remove(app)
      }
      return
    }
    let focus = await mac.focus()
    // The focus was read before the wait; only the app shown then is judged by it.
    guard quickApp.shown?.app == shown.app else { return }
    let current = mac.spaces().first { $0.spaces.contains { $0.id == shown.space } }?.currentSpace
    let left = focus.app != nil && focus.app != shown.app
    guard left || current != shown.space else { return }
    // Counted hidden only once macOS says so; until then the next hint tries again.
    guard mac.setAppHidden(shown.app, true), mac.isAppHidden(shown.app) == true else { return }
    if quickApp.shown?.app == shown.app { quickApp.shown = nil }
  }
}
