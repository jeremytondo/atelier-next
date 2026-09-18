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
    let atelier = Atelier(mac: mac, patience: patience)

    // The first waits on a switch that never comes.
    let first = Task { try await atelier.spaces.next() }
    while mac.requests.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
    await #expect(throws: AtelierError.busy) { try await atelier.windows.select(2) }
    await #expect(throws: AtelierError.busy) { try await atelier.desktops.delete() }
    // A query is not a command.
    #expect(try await atelier.slots() == [1, 2])
    #expect(mac.requests == ["switch to 2"])

    await #expect(throws: AtelierError.self) { try await first.value }
    // Dropped, not queued: nothing ran once the first finished.
    #expect(mac.requests == ["switch to 2"])
    #expect(try await atelier.windows.select(2) == .changed)
  }

  @Test func windowChangesAreAnnounced() async throws {
    let mac = FakeMac(focusedWindow: 1, windows: [window(1)])
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    var changes = await atelier.windows.changes().makeAsyncIterator()
    // The Mac hints; Atelier looks, and tells its listeners what kind of change it saw.
    mac.change { $0.windows.append(window(2)) }
    mac.hint()
    await changes.next()
    #expect(try await atelier.slots() == [1, 2])
  }

  @Test func reorderingTheListIsAnnounced() async throws {
    let mac = FakeMac(focusedWindow: 1, windows: [window(1), window(2)])
    let atelier = Atelier(mac)
    _ = try await atelier.slots()
    var changes = await atelier.windows.changes().makeAsyncIterator()
    #expect(try await atelier.windows.move(.by(1)) == .changed)
    await changes.next()
  }

  @Test func spaceChangesAreAnnounced() async throws {
    let mac = FakeMac.oneDisplay()
    let atelier = Atelier(mac)
    _ = try await atelier.spaces.list()
    var changes = await atelier.spaces.changes().makeAsyncIterator()
    #expect(try await atelier.desktops.new() == .changed)
    await changes.next()
  }
}
