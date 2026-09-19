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
  /// In slot order: the first window is number one, on the display named
  /// as WindowServer names it. See `WindowLists` for how the order comes
  /// about and what changes it.
  case desktop([Window], display: String)
  /// Keyboard input is going to a full-screen or Split View Space.
  case notDesktop
}

public enum CycleDirection: Hashable, Sendable {
  case next, previous
}

/// The `windows` subject: the current Desktop's numbered windows. The current
/// Desktop is the one receiving keyboard input.
public struct Windows: Sendable {
  let workspace: Workspace

  /// `windows.list`
  public func list() async throws(AtelierError) -> WindowList {
    try await workspace.windowList()
  }

  /// `windows.select`: shows the window in a one-based slot if it is
  /// minimized or hidden, brings exactly that window forward, and confirms it
  /// has the keyboard. Nothing to do for an empty slot or off a Desktop.
  public func select(_ slot: Int) async throws(AtelierError) -> Outcome {
    try await workspace.selectWindow(slot)
  }

  /// `windows.cycle`: the listed window after or before the focused one,
  /// wrapping. With no listed window focused, next is the first and previous
  /// the last.
  public func cycle(_ direction: CycleDirection) async throws(AtelierError) -> Outcome {
    try await workspace.cycleWindow(direction)
  }

  /// `windows.move`: gives the focused window another slot, held within the
  /// list. Only the numbering changes: no window moves, and focus stays put.
  public func move(_ move: WindowMove) async throws(AtelierError) -> Outcome {
    try await workspace.moveFocusedWindow(move)
  }

  /// Yields after the windows of any Desktop, their order, or the focused
  /// window changed.
  public func changes() async -> AsyncStream<Void> {
    await workspace.changes(to: .windows)
  }
}

extension Workspace {
  func selectWindow(_ slot: Int) async throws(AtelierError) -> Outcome {
    try await run { observation async throws(AtelierError) in
      guard slot >= 1, let list = lists.byDesktop[observation.space.id],
        list.indices.contains(slot - 1)
      else { return .unchanged }
      try await focus(list[slot - 1], from: observation)
      return .changed
    }
  }

  func cycleWindow(_ direction: CycleDirection) async throws(AtelierError) -> Outcome {
    try await run { observation async throws(AtelierError) in
      guard let list = lists.byDesktop[observation.space.id], !list.isEmpty else {
        return .unchanged
      }
      let focused = observation.focusedWindow(in: list).flatMap(list.firstIndex)
      let index =
        switch direction {
        case .next: focused.map { ($0 + 1) % list.count } ?? 0
        case .previous: focused.map { ($0 + list.count - 1) % list.count } ?? list.count - 1
        }
      try await focus(list[index], from: observation)
      return .changed
    }
  }

  func moveFocusedWindow(_ move: WindowMove) async throws(AtelierError) -> Outcome {
    try await run { observation async throws(AtelierError) in
      let desktop = observation.space.id
      guard let window = observation.focusedWindow(in: lists.byDesktop[desktop] ?? []),
        moveWindow(window, on: desktop, move)
      else { return .unchanged }
      return .changed
    }
  }

  func windowList() async throws(AtelierError) -> WindowList {
    let observation = try await observe()
    guard observation.space.isDesktop else { return .notDesktop }
    return .desktop(
      Self.windows(
        lists.byDesktop[observation.space.id] ?? [], in: observation.snapshot,
        focused: observation.focus.window), display: observation.display.id)
  }

  /// A window counts as focused when it has the keyboard or, once it was
  /// asked forward, when a dialog or sheet of its app keeps the keyboard:
  /// that is the app's say, and it is respected.
  func focus(_ window: WindowIdentity, from observation: Observation) async throws(AtelierError) {
    guard observation.focusedWindow(in: [window]) == nil else { return }
    let name =
      observation.snapshot.windows.first { WindowIdentity($0) == window }?.appName ?? "the app"
    switch await mac.raise(window: window.id, of: window.app) {
    case .asked: break
    case .closed: throw .failed("The selected window closed.")
    case .unanswered: throw .failed("\(name) is not responding.")
    }
    let hasFocus = await wait(patience.focus) {
      let focus = await mac.focus()
      return focus.app == window.app
        && (focus.window == window.id || focus.window != nil && !focus.windowIsOrdinary)
    }
    guard hasFocus else { throw .failed("Could not bring the window in \(name) forward.") }
  }
}
