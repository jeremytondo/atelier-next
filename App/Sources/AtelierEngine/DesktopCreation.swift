import Foundation
import SpaceControlCore

/// Outcome of dispatching the private create operation.
enum CreationDispatch: Equatable {
  case created(UInt64)
  /// Nothing ran: the bridge was unavailable or refused before dispatch.
  case refused(String)
  /// The operation ran but returned no ID, so the outcome is unknown.
  case uncertain(String)
}

/// The native seams Desktop creation drives. Production closures read and act
/// on live macOS state; tests supply fakes.
struct DesktopCreationSeams {
  var topology: () -> [DisplaySpaceSnapshot]
  var missionControlVisible: () -> Bool
  var dockCount: () -> Int?
  var create: () -> CreationDispatch
  /// Posts macOS's own "Switch to Desktop N" action for a global number.
  var enterDesktop: (Int) -> Bool
  var poller: Poller
}

struct DesktopCreationError: LocalizedError {
  let message: String
  let createdID: UInt64?
  var errorDescription: String? {
    guard let createdID else { return message }
    return "\(message). Desktop \(createdID) was created; check Mission Control before trying again"
  }
}

/// Creates one Desktop, which macOS appends after the display's existing
/// Spaces, and enters it with macOS's own numbered switch, never opening
/// Mission Control. Every step is confirmed against fresh topology, a failure
/// after dispatch reports the created ID, and nothing is ever re-dispatched.
enum DesktopCreation {
  static let confirmationTimeout: TimeInterval = 1
  static let entryTimeout: TimeInterval = 3
  /// macOS registers numbered Desktop shortcuts for the first sixteen Desktops.
  static let maximumNumberedDesktop = 16

  /// The new Desktop's ID once it has been entered.
  static func createAndEnter(on display: String, seams: DesktopCreationSeams) throws -> UInt64 {
    let before = seams.topology()
    guard before.count == 1, before[0].identifier == display else {
      throw DesktopCreationError(
        message: "Desktop creation supports one display for now", createdID: nil)
    }
    guard let current = before[0].spaces.first(where: { $0.id == before[0].currentSpaceID }),
      current.rawType == 0, !current.isFullscreen
    else {
      throw DesktopCreationError(
        message: "Leave the full-screen app before creating a Desktop", createdID: nil)
    }
    guard !seams.missionControlVisible() else {
      throw DesktopCreationError(
        message: "Close Mission Control before creating a Desktop", createdID: nil)
    }
    guard let dockBefore = seams.dockCount() else {
      throw DesktopCreationError(message: "Dock's Desktop list is unavailable", createdID: nil)
    }

    let id: UInt64
    switch seams.create() {
    case .created(let created): id = created
    case .refused(let reason), .uncertain(let reason):
      throw DesktopCreationError(message: reason, createdID: nil)
    }
    func failure(_ message: String) -> DesktopCreationError {
      DesktopCreationError(message: message, createdID: id)
    }

    var observation = CreationObservation.pending
    var created = before
    _ = seams.poller.wait(confirmationTimeout) {
      created = seams.topology()
      observation = SpaceTopology.confirmCreation(
        id: id, on: display, before: before, after: created)
      return observation != .pending
    }
    switch observation {
    case .verified: break
    case .pending: throw failure("macOS did not confirm the new Desktop")
    case .rejected(let reason): throw failure(reason)
    }

    let registration = try DockRegistration.observe(
      expectedCount: dockBefore + 1,
      read: {
        guard seams.topology() == created else {
          throw failure("Desktops changed while Dock registered the new one")
        }
        guard let count = seams.dockCount() else {
          throw failure("Dock's Desktop list became unavailable")
        }
        return count
      }, now: seams.poller.now, pause: seams.poller.pause)
    guard registration.confirmed else { throw failure("Dock did not register the new Desktop") }

    guard let number = SpaceTopology.globalDesktopNumber(for: id, displays: created),
      number <= maximumNumberedDesktop
    else {
      throw failure("macOS has no numbered shortcut beyond Desktop \(maximumNumberedDesktop)")
    }
    guard seams.enterDesktop(number) else { throw failure("Native Desktop shortcut unavailable") }
    guard
      seams.poller.wait(
        entryTimeout,
        until: {
          seams.topology().first(where: { $0.identifier == display })?.currentSpaceID == id
        })
    else { throw failure("Native shortcut sent but the new Desktop was not verified") }
    return id
  }
}
