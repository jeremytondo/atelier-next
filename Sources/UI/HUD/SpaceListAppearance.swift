import AtelierKit

/// When the list of Spaces shows during one hold of its keys. It appears
/// once the keys have been held for the delay, and a dismissal lasts for the
/// rest of the hold: nothing brings the list back until the keys are
/// released and held again.
struct SpaceListAppearance: Equatable {
  enum Phase: Equatable {
    /// The keys are up.
    case released
    /// The keys are held, and the list appears once the delay has passed.
    case waiting(Duration)
    case shown
    /// The keys are held and the list is not wanted. When it is again, the
    /// wait starts over.
    case suppressed
    case dismissed
  }

  private(set) var phase = Phase.released

  mutating func keys(_ hold: SpaceListHold) {
    switch (hold, phase) {
    case (.released, _): phase = .released
    case (_, .dismissed), (.held, .waiting), (.held, .shown): break
    case (.suppressed, _): phase = .suppressed
    case (.held(let delay), .released), (.held(let delay), .suppressed):
      phase = delay == .zero ? .shown : .waiting(delay)
    }
  }

  /// Whoever keeps the time says so when a wait is over. Late, it means nothing.
  mutating func delayPassed() {
    if case .waiting = phase { phase = .shown }
  }

  /// A Space was chosen, or the leader took over.
  mutating func dismiss() {
    if phase != .released { phase = .dismissed }
  }
}
