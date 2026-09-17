import AtelierKit
import MacOS
import Testing

/// One command at a time, and news of changes.
@Suite struct WorkspaceTests {
  @Test func aCommandThatArrivesWhileAnotherRunsIsDropped() async throws {
    let mac = FakeMac.oneDisplay(focusedWindow: 1, windows: [window(1), window(2)])
    mac.change { $0.ignoresSwitches = true }
    var patience = Patience.short
    patience.transition = .milliseconds(400)
    let session = Session(mac: mac, patience: patience)

    // The first waits on a switch that never comes.
    let first = Task { try await session.spaces.next() }
    while mac.requests.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
    await #expect(throws: AtelierError.busy) { try await session.windows.select(2) }
    await #expect(throws: AtelierError.busy) { try await session.desktops.delete() }
    // A query is not a command.
    #expect(try await session.slots() == [1, 2])
    #expect(mac.requests == ["switch to 2"])

    await #expect(throws: AtelierError.self) { try await first.value }
    // Dropped, not queued: nothing ran once the first finished.
    #expect(mac.requests == ["switch to 2"])
    #expect(try await session.windows.select(2) == .done)
  }

  @Test func windowChangesAreAnnounced() async throws {
    let mac = FakeMac(focusedWindow: 1, windows: [window(1)])
    let session = Session(mac)
    _ = try await session.slots()
    var changes = await session.windows.changes().makeAsyncIterator()
    // The Mac hints; Atelier looks, and tells its listeners what kind of change it saw.
    mac.change { $0.windows.append(window(2)) }
    mac.hint()
    await changes.next()
    #expect(try await session.slots() == [1, 2])
  }

  @Test func reorderingTheListIsAnnounced() async throws {
    let mac = FakeMac(focusedWindow: 1, windows: [window(1), window(2)])
    let session = Session(mac)
    _ = try await session.slots()
    var changes = await session.windows.changes().makeAsyncIterator()
    #expect(try await session.windows.move(.by(1)) == .done)
    await changes.next()
  }

  @Test func spaceChangesAreAnnounced() async throws {
    let mac = FakeMac.oneDisplay()
    let session = Session(mac)
    _ = try await session.spaces.list()
    var changes = await session.spaces.changes().makeAsyncIterator()
    #expect(try await session.desktops.new() == .done)
    await changes.next()
  }
}
