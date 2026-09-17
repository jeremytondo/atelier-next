import MacOS

public struct Window: Equatable, Identifiable, Sendable {
  public let id: UInt32
  public let app: String
  public let title: String
  public let isFocused: Bool
  /// False while minimized or while its app is hidden.
  public let isVisible: Bool

  public init(id: UInt32, app: String, title: String, isFocused: Bool, isVisible: Bool) {
    self.id = id
    self.app = app
    self.title = title
    self.isFocused = isFocused
    self.isVisible = isVisible
  }
}

public enum WindowList: Equatable, Sendable {
  /// The focused window, then other visible windows front to back, then
  /// minimized and hidden ones. The order is fresh each time, not stable.
  case desktop([Window])
  /// Keyboard input is going to a full-screen or Split View Space.
  case notDesktop
}

public enum WindowListError: Error, Equatable, Sendable {
  case accessibilityRequired
  /// macOS would not describe its windows or Spaces.
  case unavailable
}

/// Where keyboard input was going at one moment. Atelier's own interface takes
/// this before it appears, so that showing it does not change the answer.
public struct FocusContext: Sendable {
  let focus: Focus
}

/// The `windows` subject. This first query exists to prove the layers; the
/// finished window lists arrive with Desktop and window operations.
public struct Windows: Sendable {
  let mac: any Mac

  public func context() async -> FocusContext {
    FocusContext(focus: await mac.focus())
  }

  /// `windows.list`: the ordinary windows of the current Desktop, which is the
  /// Desktop receiving keyboard input.
  public func list(in context: FocusContext? = nil) async throws(WindowListError) -> WindowList {
    guard mac.hasAccessibility else { throw .accessibilityRequired }
    async let snapshotNow = mac.snapshot()
    let focus = if let context { context.focus } else { await mac.focus() }
    guard let snapshot = await snapshotNow else { throw .unavailable }

    // The focused window says which Space has the keyboard, which matters
    // when several displays each show one. The active Space answers when no
    // window has focus or the focused window is on every Space.
    let shown = Set(snapshot.displays.map(\.currentSpace))
    let focusedSpaces = shown.intersection(focus.windowSpaces)
    let current = focusedSpaces.count == 1 ? focusedSpaces.first! : focus.activeSpace

    guard let space = snapshot.displays.flatMap(\.spaces).first(where: { $0.id == current })
    else { throw .unavailable }
    guard space.isDesktop else { return .notDesktop }

    let windows = snapshot.windows
      .filter { $0.isOrdinary && $0.spaces.contains(current) }
      .map {
        Window(
          id: $0.id, app: $0.app, title: $0.title, isFocused: $0.id == focus.window,
          isVisible: $0.isOnScreen)
      }
    // The sort is stable, so front-to-back order survives within each rank.
    return .desktop(windows.sorted { rank($0) < rank($1) })
  }

  private func rank(_ window: Window) -> Int {
    window.isFocused ? 0 : window.isVisible ? 1 : 2
  }
}
