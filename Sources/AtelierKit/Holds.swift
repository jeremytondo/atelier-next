import MacOS

/// What the modifier keys held say about the two lists that show while
/// theirs are held.
public struct ListHolds: Equatable, Sendable {
  /// The window list's modifiers are held. Shift may join them, so the
  /// reorder shortcuts can be pressed while the list shows; any other
  /// modifier is a different chord.
  public let windows: Bool
  public let spaces: SpaceListHold
}

/// One hold of the Space list's modifiers lasts from `released` to
/// `released`, whatever comes between.
public enum SpaceListHold: Equatable, Sendable {
  /// One of the list's modifiers is up, or the list is turned off.
  case released
  /// The list's modifiers are held, with Shift or without, as for the window
  /// list. The list is wanted once they have been held for `delay`.
  case held(delay: Duration)
  /// They are held, and the list is not wanted: there are others with them,
  /// which is some other chord, or they are the window list's too, which
  /// comes first.
  case suppressed
}

/// The `holds` subject: the lists that show while modifier keys are held.
/// Listening to the modifiers is all that is always on, and it consumes
/// nothing. None of this touches a shortcut, which works whether or not a
/// list shows.
public struct Holds: Sendable {
  let mac: any Mac
  let config: ConfigStore

  /// Yields what the keys held say, whenever that changes, by the
  /// configuration in effect at that moment.
  public func changes() -> AsyncStream<ListHolds> {
    // Every change is kept, since a release missed would join two holds into one.
    let (stream, continuation) = AsyncStream.makeStream(of: ListHolds.self)
    let reading = Task {
      var last = ListHolds(windows: false, spaces: .released)
      for await modifiers in await mac.modifierChanges() {
        let holds = ListHolds(modifiers, await config.current)
        guard holds != last else { continue }
        last = holds
        continuation.yield(holds)
      }
    }
    continuation.onTermination = { _ in reading.cancel() }
    return stream
  }
}

extension ListHolds {
  init(_ modifiers: Chord.Modifiers, _ configuration: Configuration) {
    /// Every one of `wanted` and nothing else, save Shift.
    func holds(_ wanted: Chord.Modifiers) -> Bool {
      modifiers.isSuperset(of: wanted) && modifiers.subtracting(wanted).isSubset(of: [.shift])
    }
    let spaceList = configuration.spaceList
    windows = holds(configuration.windowListModifiers)
    spaces =
      if !spaceList.isEnabled || !modifiers.isSuperset(of: spaceList.modifiers) {
        .released
      } else if holds(spaceList.modifiers), !windows {
        .held(delay: spaceList.delay)
      } else {
        .suppressed
      }
  }
}
