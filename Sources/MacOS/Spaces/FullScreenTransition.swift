import Foundation

/// Observes a posted full-screen activation. Fronting the target may change
/// the origin Space's remembered app even if focus confirmation fails, so
/// every exit repairs that record when the origin is known to be offscreen.
/// A user switch back to the origin must never be overwritten by the repair.
/// The repair is a courtesy: whether it took never changes the result.
struct FullScreenTransition: Sendable {
  let space: UInt64
  let display: String
  let origin: UInt64?

  func confirm(
    displays: @Sendable () -> [DisplaySpaces],
    isFocused: @Sendable () async -> Bool,
    restoreOrigin: @Sendable () -> Void,
    timeout: Duration = .seconds(3),
    settling: Duration = .milliseconds(75)
  ) async -> SpaceDispatch {
    let deadline = ContinuousClock.now + timeout
    var focusedSince: ContinuousClock.Instant?
    var arrived = false
    while ContinuousClock.now < deadline {
      let snapshot = displays()
      guard let screen = snapshot.first(where: { $0.id == display }),
        screen.spaces.contains(where: { $0.id == space && !$0.isDesktop })
      else { break }
      if screen.currentSpace == space, await isFocused() {
        let now = ContinuousClock.now
        if let focusedSince, now - focusedSince >= settling {
          arrived = true
          break
        }
        if focusedSince == nil { focusedSince = now }
      } else {
        focusedSince = nil
      }
      do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
    }

    // Read again immediately before repair: confirmation awaited AX and the
    // user may have changed Spaces, or the origin may have moved displays.
    if let origin,
      let screen = displays().first(where: { $0.spaces.contains(where: { $0.id == origin }) }),
      screen.currentSpace != origin
    {
      restoreOrigin()
    }
    guard arrived else {
      return .uncertain("macOS did not confirm the full-screen Space and its focused window.")
    }
    return .sent
  }
}
