/// Keeps what a list shows current while the list is wanted. It listens for
/// changes before it first reads, so none is missed, and only the newest
/// read is ever shown: one overtaken by a change, or still under way at
/// `stop`, is thrown away, whether or not the next `start` has come.
@MainActor
final class Following<Value> {
  private(set) var value: Value?
  /// Runs after `value` was read anew.
  var onChange: () -> Void = {}
  private let changes: @Sendable () async -> AsyncStream<Void>
  private let read: @Sendable () async -> Value?
  private var listening: Task<Void, Never>?
  private var reads = 0

  /// `read` answers nil when there is nothing to show.
  init(
    changes: @escaping @Sendable () async -> AsyncStream<Void>,
    read: @escaping @Sendable () async -> Value?
  ) {
    self.changes = changes
    self.read = read
  }

  func start() {
    guard listening == nil else { return }
    listening = Task { [weak self] in
      // Stopped while subscribing, this is no longer the follower's listening.
      guard let changes = await self?.changes(), !Task.isCancelled else { return }
      self?.refresh()
      for await _ in changes {
        guard !Task.isCancelled else { return }
        self?.refresh()
      }
    }
  }

  func stop() {
    listening?.cancel()
    listening = nil
    reads += 1
    value = nil
  }

  /// Reads without holding up the listening, so a change during a read
  /// starts the next at once and the first is never shown.
  private func refresh() {
    reads += 1
    let mine = reads
    Task {
      let value = await read()
      guard mine == reads else { return }
      self.value = value
      onChange()
    }
  }
}
