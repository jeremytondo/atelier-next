import MacOS

/// The `desktops` subject: making and deleting Desktops, and switching by
/// Desktop number. Full-screen and Split View Spaces are not Desktops; none
/// of this applies to them, and Desktop numbers skip them. Reordering is
/// `spaces.move`, since a Space of any kind can be moved.
///
/// Every change names its Desktop by macOS's own number for it, never by
/// position, checks that the Spaces are still as they were when the target
/// was chosen, and afterwards confirms the result in a fresh reading. Nothing
/// is tried twice. For now Desktops are managed on a Mac with one display.
public struct Desktops: Sendable {
  let workspace: Workspace

  /// `desktops.new`: adds one Desktop after the last Space and switches to it.
  public func new() async throws(AtelierError) -> Outcome {
    try await workspace.newDesktop()
  }

  /// `desktops.select`: the Desktop with a one-based number, counting Desktops
  /// only. Nothing to do for a number with no Desktop.
  public func select(number: Int) async throws(AtelierError) -> Outcome {
    try await workspace.selectDesktop(number)
  }

  /// `desktops.delete`: switches to the next Desktop, or the previous one
  /// from the last, then deletes the Desktop it left. macOS moves that
  /// Desktop's windows to the one now showing, where they join the list as
  /// arrivals. The only Desktop left cannot be deleted.
  public func delete() async throws(AtelierError) -> Outcome {
    try await workspace.deleteDesktop()
  }
}

extension Workspace {
  /// The display and its current Desktop, for a command that changes Desktops.
  private func desktopTarget(_ observation: Observation, to what: String)
    throws(AtelierError) -> (display: DisplaySpaces, desktop: Space)
  {
    let displays = observation.snapshot.displays
    guard displays.count == 1, let display = displays.first else {
      throw .unsupported("Atelier can \(what) Desktops only with one display for now.")
    }
    guard observation.space.isDesktop else {
      throw .failed("Leave the full-screen or Split View Space to \(what) a Desktop.")
    }
    // With one display these agree unless something changed mid-census.
    guard observation.space.id == display.currentSpace else {
      throw .targetChanged("The current Desktop changed.")
    }
    return (display, observation.space)
  }

  func confirmed(_ expected: DisplaySpaces) async -> Bool {
    await wait(patience.confirmation) { mac.spaces() == [expected] }
  }

  /// `done` is what would have been, for saying that it was not.
  func check(_ dispatch: SpaceDispatch, _ done: String, of what: String = "Desktops")
    throws(AtelierError)
  {
    switch dispatch {
    case .sent: break
    case .changed:
      throw .targetChanged("The \(what) changed just before, so nothing was \(done).")
    case .refused(let reason): throw .unsupported(reason)
    case .uncertain(let reason): throw .uncertain(reason)
    }
  }

  func selectDesktop(_ number: Int) async throws(AtelierError) -> Outcome {
    announce(.selection)
    return try await run { observation async throws(AtelierError) in
      let desktops = observation.display.desktops
      guard number >= 1, desktops.indices.contains(number - 1),
        desktops[number - 1] != observation.space
      else { return .unchanged }
      try await go(
        to: desktops[number - 1].id, on: observation.display.id,
        in: observation.snapshot.displays)
      return .changed
    }
  }

  func newDesktop() async throws(AtelierError) -> Outcome {
    try await run { observation async throws(AtelierError) in
      let (display, _) = try desktopTarget(observation, to: "create")
      switch await mac.isMissionControlOpen() {
      case false: break
      case true: throw .failed("Close Mission Control to create a Desktop.")
      case nil: throw .unsupported("Dock would not say whether Mission Control is open.")
      }

      let created: UInt64
      switch await mac.createDesktop(expecting: [display]) {
      case .created(let id): created = id
      case .changed:
        throw .targetChanged("The Desktops changed just before, so none was created.")
      case .refused(let reason): throw .unsupported(reason)
      case .uncertain(let reason): throw .uncertain(reason)
      }
      // Exactly one new Desktop, last, with everything else as it was.
      let expected = DisplaySpaces(
        id: display.id, currentSpace: display.currentSpace,
        spaces: display.spaces + [Space(id: created, isDesktop: true)])
      guard await confirmed(expected) else {
        throw .desktopCreated(
          created, then: "macOS made Desktop \(created) but it did not appear as expected.")
      }
      do {
        try await go(to: created, on: display.id, in: [expected])
      } catch {
        throw .desktopCreated(
          created, then: "The new Desktop was made, but Atelier could not switch to it.")
      }
      return .changed
    }
  }

  func deleteDesktop() async throws(AtelierError) -> Outcome {
    try await run { observation async throws(AtelierError) in
      let (display, doomed) = try desktopTarget(observation, to: "delete")
      let desktops = display.desktops
      guard desktops.count > 1, let place = desktops.firstIndex(of: doomed) else {
        throw .failed("The only Desktop cannot be deleted.")
      }
      let destination = desktops[place + 1 < desktops.count ? place + 1 : place - 1]
      try await go(to: destination.id, on: display.id, in: [display])

      // Only the Desktop just left, still where it was, is deleted.
      let left = DisplaySpaces(
        id: display.id, currentSpace: destination.id, spaces: display.spaces)
      try check(await mac.destroySpace(doomed.id, expecting: [left]), "deleted")
      let expected = DisplaySpaces(
        id: display.id, currentSpace: destination.id,
        spaces: display.spaces.filter { $0 != doomed })
      guard await confirmed(expected) else {
        throw .uncertain("macOS did not confirm the deletion. Check Mission Control.")
      }
      forgetList(of: doomed.id)
      return .changed
    }
  }
}
