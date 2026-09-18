/// How a command ended when nothing went wrong: it changed something, or
/// there was nothing to do. Nothing to do is a success, as with `mkdir -p`.
public enum Outcome: Equatable, Sendable {
  case changed
  /// No such slot, already there, or already at the end.
  case unchanged
}

public enum AtelierError: Error, Equatable, Sendable {
  case accessibilityRequired
  /// macOS would not describe its windows or Spaces.
  case unavailable
  /// Another command was still running. This one was dropped, not queued,
  /// since by the time it ran the current Desktop might be another one.
  case busy
  /// This Mac's displays or this macOS cannot do it.
  case unsupported(String)
  /// What the command was aimed at changed before it could act. Nothing was done.
  case targetChanged(String)
  /// Nothing was changed.
  case failed(String)
  /// macOS was asked to change Desktops and the result could not be
  /// confirmed, so the change may have happened. Look before trying again.
  case uncertain(String)
  /// A Desktop was made, with this number from macOS, and then something
  /// went wrong. Trying again would make another.
  case desktopCreated(UInt64, then: String)

  public var message: String {
    switch self {
    case .accessibilityRequired:
      "Atelier needs the Accessibility permission. Open Atelier in the menu bar to grant it."
    case .unavailable: "macOS did not describe its windows and Spaces. Try again."
    case .busy: "Atelier is busy with another command."
    case .unsupported(let reason), .targetChanged(let reason), .failed(let reason),
      .uncertain(let reason), .desktopCreated(_, let reason):
      reason
    }
  }
}
