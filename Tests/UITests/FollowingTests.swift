import Testing

@testable import UI

/// Something to follow, which a test changes and answers for by hand.
@MainActor
private final class Source {
  private(set) var subscriptions = 0
  private(set) var waiting: [CheckedContinuation<Int?, Never>] = []
  private var listeners: [AsyncStream<Void>.Continuation] = []

  func subscribe() -> AsyncStream<Void> {
    subscriptions += 1
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    listeners.append(continuation)
    return stream
  }

  func read() async -> Int? {
    await withCheckedContinuation { waiting.append($0) }
  }

  func change() {
    for listener in listeners { listener.yield() }
  }

  /// Answers the oldest read still waiting.
  func answer(_ value: Int?) {
    waiting.removeFirst().resume(returning: value)
  }
}

@MainActor
@Suite struct FollowingTests {
  private let source = Source()

  private func following() -> Following<Int> {
    let source = source
    return Following(changes: { await source.subscribe() }, read: { await source.read() })
  }

  /// True as soon as `condition` holds, within a second.
  private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    return condition()
  }

  @Test func listensBeforeItReadsAndReadsAgainAfterEachChange() async {
    let following = following()
    var changes = 0
    following.onChange = { changes += 1 }
    following.start()
    #expect(await eventually { source.waiting.count == 1 })
    #expect(source.subscriptions == 1)
    source.answer(1)
    #expect(await eventually { following.value == 1 })
    source.change()
    #expect(await eventually { source.waiting.count == 1 })
    source.answer(2)
    #expect(await eventually { following.value == 2 })
    #expect(changes == 2)
    // Started already, so nothing starts again.
    following.start()
    #expect(source.subscriptions == 1)
  }

  @Test func aReadThatEndsAfterStopShowsNothing() async {
    let following = following()
    var changes = 0
    following.onChange = { changes += 1 }
    following.start()
    #expect(await eventually { source.waiting.count == 1 })
    following.stop()
    source.answer(1)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(following.value == nil)
    #expect(changes == 0)
    // Changes after the stop are not read at all.
    source.change()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(source.waiting.isEmpty)
  }

  @Test func aReadFromBeforeTheStopNeverPassesForTheNextStartsOwn() async {
    let following = following()
    following.start()
    #expect(await eventually { source.waiting.count == 1 })
    following.stop()
    following.start()
    #expect(await eventually { source.waiting.count == 2 })
    // The old read answers last of all it could, and first.
    source.answer(9)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(following.value == nil)
    source.answer(2)
    #expect(await eventually { following.value == 2 })
  }

  @Test func aReadOvertakenByAChangeIsNeverShown() async {
    let following = following()
    var shown: [Int?] = []
    following.onChange = { shown.append(following.value) }
    following.start()
    #expect(await eventually { source.waiting.count == 1 })
    // The keyboard went to another display, say, while the first read was under way.
    source.change()
    #expect(await eventually { source.waiting.count == 2 })
    source.answer(1)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(following.value == nil)
    source.answer(2)
    #expect(await eventually { following.value == 2 })
    #expect(shown == [2])
  }

  @Test func stoppingForgetsWhatWasRead() async {
    let following = following()
    following.start()
    #expect(await eventually { source.waiting.count == 1 })
    source.answer(1)
    #expect(await eventually { following.value == 1 })
    following.stop()
    #expect(following.value == nil)
  }
}
