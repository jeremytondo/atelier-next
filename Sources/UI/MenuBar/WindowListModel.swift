import AtelierKit
import Observation

/// What the popover shows. It asks AtelierKit when told to and, while
/// following, whenever AtelierKit says the windows changed.
@MainActor @Observable
final class WindowListModel {
  enum State: Equatable {
    case loading
    case loaded(WindowList)
    case needsAccessibility
    case failed(String)
  }

  private(set) var state = State.loading
  /// Where keyboard input was going before the popover took it.
  private var context: FocusContext?
  private var refreshes = 0
  private var following: Task<Void, Never>?

  private let session: Session
  private let changed: @MainActor () -> Void

  init(session: Session, changed: @escaping @MainActor () -> Void) {
    self.session = session
    self.changed = changed
  }

  /// Call before the popover shows: once it has, Atelier is the focus.
  func captureContext() async {
    // An answer still on its way belongs to the previous opening.
    refreshes += 1
    context = await session.windows.context()
    state = .loading
  }

  func refresh() async {
    refreshes += 1
    let refresh = refreshes
    let result: State
    do {
      result = .loaded(try await session.windows.list(in: context))
    } catch .accessibilityRequired {
      result = .needsAccessibility
    } catch {
      result = .failed(error.message)
    }
    // A slow answer must not replace the answer to a later request.
    guard refresh == refreshes else { return }
    state = result
    changed()
  }

  /// Keeps the list current until `stopFollowing`, while the popover is open.
  func follow() {
    following?.cancel()
    following = Task {
      for await _ in await session.windows.changes() { await refresh() }
    }
  }

  func stopFollowing() {
    following?.cancel()
    following = nil
  }

  func requestAccessibility() {
    session.permissions.requestAccessibility()
  }
}
