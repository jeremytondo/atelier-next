import MacOS

public struct SpaceInfo: Equatable, Sendable {
  /// macOS's own number for the Space, which it keeps as Spaces are reordered.
  public let id: UInt64
  /// One-based, counting Desktops only; nil for a full-screen or Split View Space.
  public let desktopNumber: Int?
  public let isCurrent: Bool
}

/// The Spaces of the display receiving keyboard input, in Mission Control
/// order. A Space's position is its one-based place here, whatever its kind.
public struct SpaceList: Equatable, Sendable {
  public let display: String
  public let spaces: [SpaceInfo]
}

/// The `spaces` subject: moving between Spaces of every kind. Desktops,
/// full-screen windows, and Split View pairs are one sequence here, in
/// Mission Control order. Managing Desktops is the `desktops` subject.
public struct Spaces: Sendable {
  let workspace: Workspace

  /// `spaces.list`
  public func list() async throws(AtelierError) -> SpaceList {
    SpaceList(try await workspace.observe().display)
  }

  /// `spaces.next`: the Space after the current one, or the first after the last.
  public func next() async throws(AtelierError) -> Outcome {
    try await workspace.goToSpace { current, count in (current + 1) % count }
  }

  /// `spaces.previous`: the Space before the current one, or the last before the first.
  public func previous() async throws(AtelierError) -> Outcome {
    try await workspace.goToSpace { current, count in (current + count - 1) % count }
  }

  /// `spaces.select`: the Space at a one-based position among every kind of
  /// Space. Nothing to do for a position past the end. For Desktop numbers,
  /// which skip full-screen and Split View Spaces, see `desktops.select`.
  public func select(position: Int) async throws(AtelierError) -> Outcome {
    guard position >= 1 else { return .noop }
    return try await workspace.goToSpace { _, _ in position - 1 }
  }

  /// `spaces.move`: moves the Space at one one-based position to another,
  /// the way dragging it in Mission Control would, whatever its kind and
  /// whether or not it is current. Nothing to do when either position is
  /// past the end or the two are the same.
  public func move(from: Int, to: Int) async throws(AtelierError) -> Outcome {
    try await workspace.moveSpace(from: from, to: to)
  }

  /// Yields after Spaces were added, removed, or reordered, or another became current.
  public func changes() async -> AsyncStream<Void> {
    await workspace.changes(to: .spaces)
  }
}

extension SpaceList {
  init(_ display: DisplaySpaces) {
    var desktops = 0
    self.init(
      display: display.id,
      spaces: display.spaces.map { space in
        if space.isDesktop { desktops += 1 }
        return SpaceInfo(
          id: space.id, desktopNumber: space.isDesktop ? desktops : nil,
          isCurrent: space.id == display.currentSpace)
      })
  }
}

extension DisplaySpaces {
  var desktops: [Space] { spaces.filter(\.isDesktop) }
}

extension Workspace {
  /// `choose` takes the current Space's zero-based index and the number of
  /// Spaces, and picks an index. One outside the list is nothing to do.
  func goToSpace(_ choose: @Sendable (Int, Int) -> Int) async throws(AtelierError) -> Outcome {
    try await run { observation async throws(AtelierError) in
      let spaces = observation.display.spaces
      guard let current = spaces.firstIndex(of: observation.space) else { throw .unavailable }
      let target = choose(current, spaces.count)
      guard spaces.indices.contains(target), target != current else { return .noop }
      try await go(
        to: spaces[target].id, on: observation.display.id, in: observation.snapshot.displays)
      return .done
    }
  }

  /// One display for now, since a position names a Space of one display.
  func moveSpace(from: Int, to: Int) async throws(AtelierError) -> Outcome {
    try await run { observation async throws(AtelierError) in
      let displays = observation.snapshot.displays
      guard displays.count == 1, let display = displays.first else {
        throw .unsupported("Atelier can reorder Spaces only with one display for now.")
      }
      var spaces = display.spaces
      guard from >= 1, to >= 1, spaces.indices.contains(from - 1), spaces.indices.contains(to - 1),
        from != to
      else { return .noop }
      let moved = spaces.remove(at: from - 1)
      spaces.insert(moved, at: to - 1)
      let expected = DisplaySpaces(
        id: display.id, currentSpace: display.currentSpace, spaces: spaces)

      try check(
        await mac.moveSpace(moved.id, toIndex: to - 1, onDisplay: display.id, expecting: [display]),
        "moved", of: "Spaces")
      guard await confirmed(expected) else {
        throw .uncertain("macOS did not confirm the move. Check Mission Control.")
      }
      return .done
    }
  }

  /// Makes `target` the current Space of its display and confirms it.
  /// `displays` is what the choice of target was based on; if the Spaces are
  /// no longer so, macOS is asked for nothing.
  func go(to target: UInt64, on displayID: String, in displays: [DisplaySpaces])
    async throws(AtelierError)
  {
    switch await mac.switchSpace(to: target, on: displayID, expecting: displays) {
    case .sent: break
    case .changed: throw .targetChanged("The Spaces changed before Atelier could switch.")
    case .refused(let reason): throw .unsupported(reason)
    case .uncertain(let reason): throw .failed(reason)
    }
    let arrived = await wait(patience.transition) {
      mac.spaces().first { $0.id == displayID }?.currentSpace == target
    }
    guard arrived else { throw .failed("macOS did not switch to the Space Atelier asked for.") }
  }
}
