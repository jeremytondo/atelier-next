import CoreGraphics
import Foundation
import SpaceControlCore

/// What Mission Control exposes to the reorder and delete operations: Dock's
/// Spaces bar as thumbnail frames in native Space order, plus the pointer and
/// keyboard events that drive it.
struct MissionControlSeams {
  var topology: () -> [DisplaySpaceSnapshot]
  var postSymbolicHotKey: (UInt32) -> Bool
  var isVisible: () -> Bool
  /// Thumbnail frames for a display, nil while the bar is not exposed. An
  /// unreadable frame is `.null` so indices still line up with Spaces.
  var thumbnails: (CGDirectDisplayID) -> [CGRect]?
  var press: (CGDirectDisplayID, Int) -> Bool
  var removeDesktop: (CGDirectDisplayID, Int) -> Bool
  var displayBounds: (CGDirectDisplayID) -> CGRect
  var pointer: () -> CGPoint?
  var movePointer: (CGPoint) -> Bool
  var drag: (CGPoint, CGPoint) -> Bool
  var poller: Poller
}

/// Reorders and deletes Desktops through Mission Control's own Spaces bar.
/// Every step is confirmed against fresh topology; nothing is retried.
final class MissionControl {
  /// Dock exposes its AX root before the entrance animation finishes; hovering
  /// the top edge during that animation is ignored.
  static let presentationSettleTime: TimeInterval = 0.35
  static let minimumExpandedThumbnailHeight: CGFloat = 48
  static let thumbnailSettleTime: TimeInterval = 0.25
  private let seams: MissionControlSeams
  private var pointerBeforeNavigation: CGPoint?
  private var lastSyntheticPointer: CGPoint?

  init(seams: MissionControlSeams) {
    self.seams = seams
  }

  func isVisible() -> Bool {
    seams.isVisible()
  }

  /// Opens Mission Control if needed and expands the Spaces bar on the display.
  func open(on target: TargetDisplay, topology: [DisplaySpaceSnapshot]) throws {
    if !seams.isVisible() {
      guard seams.postSymbolicHotKey(SymbolicHotKey.missionControl),
        seams.poller.wait(3, until: seams.isVisible)
      else { throw ProviderError("Could not open Mission Control") }
    }
    guard activeDesktop(on: target, topology: topology) != nil else {
      throw ProviderError("Could not resolve the current Desktop")
    }
    seams.poller.sleep(Self.presentationSettleTime)
    guard ensureExpandedSpacesBar(on: target, topology: topology) else {
      throw ProviderError("The native Spaces bar did not expand")
    }
  }

  /// Returns the pointer to where it was before the bar was expanded, unless
  /// the user has moved it since.
  func resetPointer() {
    defer {
      pointerBeforeNavigation = nil
      lastSyntheticPointer = nil
    }
    guard let original = pointerBeforeNavigation, let synthetic = lastSyntheticPointer,
      let current = seams.pointer(),
      hypot(current.x - synthetic.x, current.y - synthetic.y) <= 6
    else { return }
    _ = seams.movePointer(original)
  }

  func activateAdjacentDesktop(
    offset: Int, on target: TargetDisplay, topology: [DisplaySpaceSnapshot]
  )
    throws
  {
    guard seams.isVisible() else { throw ProviderError("Mission Control is no longer open") }
    guard let (display, currentIndex) = activeDesktop(on: target, topology: topology) else {
      throw ProviderError("No ordinary Desktop is currently active")
    }
    let desktops = display.regularDesktops
    let nextIndex = min(max(currentIndex + offset, 0), desktops.count - 1)
    guard nextIndex != currentIndex else { return }
    let destination = desktops[nextIndex]
    guard
      let currentFullIndex = display.spaces.firstIndex(where: { $0.id == desktops[currentIndex].id }
      ),
      let destinationFullIndex = display.spaces.firstIndex(where: { $0.id == destination.id })
    else { throw ProviderError("Could not resolve the adjacent Desktop route") }

    // The previous/next Space actions step through full-screen Spaces too.
    let action = offset < 0 ? SymbolicHotKey.previousSpace : SymbolicHotKey.nextSpace
    let step = offset < 0 ? -1 : 1
    for fullIndex in stride(from: currentFullIndex + step, through: destinationFullIndex, by: step)
    {
      let expected = display.spaces[fullIndex].id
      guard seams.postSymbolicHotKey(action),
        seams.poller.wait(3, until: { self.currentSpaceID(on: target) == expected }),
        seams.poller.wait(2, until: seams.isVisible)
      else {
        throw ProviderError(
          "macOS did not keep Mission Control open while activating Desktop \(nextIndex + 1)")
      }
    }
    let updated = seams.topology()
    guard currentSpaceID(on: target, in: updated) == destination.id,
      ensureExpandedSpacesBar(on: target, topology: updated)
    else { throw ProviderError("The active Desktop thumbnail did not remain expanded") }
  }

  func enterActiveDesktop(on target: TargetDisplay, topology: [DisplaySpaceSnapshot]) throws {
    guard seams.isVisible() else { throw ProviderError("Mission Control is no longer open") }
    guard let (display, activeIndex) = activeDesktop(on: target, topology: topology) else {
      throw ProviderError("No ordinary Desktop is currently active")
    }
    let active = display.regularDesktops[activeIndex]
    guard let fullIndex = display.spaces.firstIndex(where: { $0.id == active.id }),
      waitForExpandedThumbnail(
        on: target.displayID, index: fullIndex, expectedCount: display.spaces.count, timeout: 2)
    else { throw ProviderError("Could not resolve the active Desktop thumbnail") }
    guard seams.press(target.displayID, fullIndex) else {
      throw ProviderError("The active Desktop rejected selection")
    }
    guard waitForClose(timeout: 3) || close(timeout: 2) else {
      throw ProviderError("Mission Control did not close after entering the Desktop")
    }
    guard currentSpaceID(on: target) == active.id else {
      throw ProviderError("The active Desktop changed while Mission Control closed")
    }
  }

  func reorderActiveDesktop(offset: Int, on target: TargetDisplay, topology: [DisplaySpaceSnapshot])
    throws
  {
    guard seams.isVisible() else { throw ProviderError("Mission Control is no longer open") }
    guard let (display, sourceIndex) = activeDesktop(on: target, topology: topology) else {
      throw ProviderError("No ordinary Desktop is currently active")
    }
    let desktops = display.regularDesktops
    let destinationIndex = sourceIndex + offset
    guard desktops.indices.contains(destinationIndex) else { return }
    let active = desktops[sourceIndex]
    let count = display.spaces.count
    guard let sourceFullIndex = display.spaces.firstIndex(where: { $0.id == active.id }),
      let destinationFullIndex = display.spaces.firstIndex(where: {
        $0.id == desktops[destinationIndex].id
      }),
      let sourceFrame = thumbnail(
        on: target.displayID, index: sourceFullIndex, expectedCount: count),
      let destinationFrame = thumbnail(
        on: target.displayID, index: destinationFullIndex, expectedCount: count),
      !sourceFrame.isNull, !destinationFrame.isNull
    else { throw ProviderError("Could not resolve the active Desktop thumbnails") }

    // Dock preserves the grab offset inside the thumbnail. Match the left-edge
    // insertion target with a left-edge grab; a center grab can skip a slot or
    // drop back into the original position.
    let sourcePoint = CGPoint(x: sourceFrame.minX + 4, y: sourceFrame.midY)
    let destinationPoint = CGPoint(
      x: offset < 0 ? destinationFrame.minX + 4 : destinationFrame.maxX - 4,
      y: destinationFrame.midY)
    guard seams.drag(sourcePoint, destinationPoint) else {
      throw ProviderError("Could not synthesize the Desktop drag")
    }
    guard
      seams.poller.wait(
        3,
        until: {
          self.display(target, in: self.seams.topology())?.regularDesktops.firstIndex(where: {
            $0.id == active.id
          }) == destinationIndex
        })
    else { throw ProviderError("macOS did not confirm the Desktop reorder") }
    guard ensureExpandedSpacesBar(on: target, topology: seams.topology()) else {
      throw ProviderError("The reordered Desktop thumbnail did not remain expanded")
    }
  }

  func deleteActiveDesktop(on target: TargetDisplay, topology: [DisplaySpaceSnapshot]) throws {
    guard seams.isVisible() else { throw ProviderError("Mission Control is no longer open") }
    guard let (display, activeIndex) = activeDesktop(on: target, topology: topology) else {
      throw ProviderError("No ordinary Desktop is currently active")
    }
    let desktops = display.regularDesktops
    guard desktops.count > 1 else { throw ProviderError("The final Desktop cannot be deleted") }
    let doomed = desktops[activeIndex]
    let neighborOffset = activeIndex < desktops.count - 1 ? 1 : -1
    let neighbor = desktops[activeIndex + neighborOffset]
    do {
      try activateAdjacentDesktop(offset: neighborOffset, on: target, topology: topology)
    } catch let error as ProviderError {
      throw ProviderError("Could not leave the active Desktop before deletion: \(error.message)")
    }

    guard let afterActivation = self.display(target, in: seams.topology()),
      afterActivation.currentSpaceID == neighbor.id,
      let fullIndex = afterActivation.spaces.firstIndex(where: { $0.id == doomed.id }),
      seams.poller.wait(
        2, stableFor: Self.thumbnailSettleTime,
        until: {
          self.thumbnail(
            on: target.displayID, index: fullIndex, expectedCount: afterActivation.spaces.count)
            != nil
        })
    else { throw ProviderError("Could not resolve the former active Desktop thumbnail") }
    guard seams.removeDesktop(target.displayID, fullIndex) else {
      throw ProviderError("Desktop \(activeIndex + 1) rejected deletion")
    }
    var updated: DisplaySpaceSnapshot?
    guard
      seams.poller.wait(
        3,
        until: {
          guard let candidate = self.display(target, in: self.seams.topology()),
            !candidate.spaces.contains(where: { $0.id == doomed.id })
          else { return false }
          updated = candidate
          return true
        }), let updated
    else { throw ProviderError("macOS did not confirm Desktop deletion") }
    guard updated.currentSpaceID == neighbor.id else {
      throw ProviderError("The neighboring Desktop did not remain active")
    }
    guard ensureExpandedSpacesBar(on: target, topology: [updated]) else {
      throw ProviderError("The neighboring Desktop thumbnail did not remain expanded")
    }
  }

  // MARK: - Topology

  private func display(_ target: TargetDisplay, in topology: [DisplaySpaceSnapshot])
    -> DisplaySpaceSnapshot?
  {
    topology.first { $0.identifier == target.topologyIdentifier }
  }

  private func currentSpaceID(on target: TargetDisplay, in topology: [DisplaySpaceSnapshot]? = nil)
    -> UInt64?
  {
    display(target, in: topology ?? seams.topology())?.currentSpaceID
  }

  private func activeDesktop(on target: TargetDisplay, topology: [DisplaySpaceSnapshot])
    -> (DisplaySpaceSnapshot, Int)?
  {
    guard let display = display(target, in: topology),
      let index = display.regularDesktops.firstIndex(where: { $0.id == display.currentSpaceID })
    else { return nil }
    return (display, index)
  }

  // MARK: - Spaces bar

  /// The thumbnail at a native Space index, only while the bar shows exactly
  /// the expected number of Spaces.
  private func thumbnail(on displayID: CGDirectDisplayID, index: Int, expectedCount: Int)
    -> CGRect?
  {
    guard let frames = seams.thumbnails(displayID), frames.count == expectedCount,
      frames.indices.contains(index)
    else { return nil }
    return frames[index]
  }

  private func ensureExpandedSpacesBar(on target: TargetDisplay, topology: [DisplaySpaceSnapshot])
    -> Bool
  {
    guard let display = display(target, in: topology),
      let currentFullIndex = display.spaces.firstIndex(where: { $0.id == display.currentSpaceID }),
      expandSpacesBar(on: target.displayID)
    else { return false }
    return waitForExpandedThumbnail(
      on: target.displayID, index: currentFullIndex, expectedCount: display.spaces.count,
      timeout: 2)
  }

  /// Hovers the top edge of the display, which Dock answers by expanding the bar.
  private func expandSpacesBar(on displayID: CGDirectDisplayID) -> Bool {
    let bounds = seams.displayBounds(displayID)
    guard !bounds.isNull, bounds.width > 2, bounds.height > 2 else { return false }
    let currentX = seams.pointer()?.x ?? bounds.midX
    let point = CGPoint(
      x: min(max(currentX, bounds.minX + 1), bounds.maxX - 1), y: bounds.minY + 1)
    if pointerBeforeNavigation == nil { pointerBeforeNavigation = seams.pointer() }
    guard seams.movePointer(point) else { return false }
    lastSyntheticPointer = point
    return true
  }

  /// True once the thumbnail is expanded and its frame has stopped moving.
  private func waitForExpandedThumbnail(
    on displayID: CGDirectDisplayID, index: Int, expectedCount: Int, timeout: TimeInterval
  ) -> Bool {
    var stable: CGRect?
    return seams.poller.wait(timeout, stableFor: Self.thumbnailSettleTime) {
      guard let frame = thumbnail(on: displayID, index: index, expectedCount: expectedCount),
        frame.height >= Self.minimumExpandedThumbnailHeight
      else {
        stable = nil
        return false
      }
      defer { stable = frame }
      guard let previous = stable else { return true }
      return abs(previous.minX - frame.minX) <= 1 && abs(previous.minY - frame.minY) <= 1
        && abs(previous.width - frame.width) <= 1 && abs(previous.height - frame.height) <= 1
    }
  }

  // MARK: - Closing

  private func close(timeout: TimeInterval) -> Bool {
    guard seams.poller.wait(0.1, until: seams.isVisible) else { return true }
    guard seams.postSymbolicHotKey(SymbolicHotKey.missionControl) else { return false }
    return waitForClose(timeout: timeout)
  }

  private func waitForClose(timeout: TimeInterval) -> Bool {
    seams.poller.wait(timeout, stableFor: 0.2) { !seams.isVisible() }
  }
}
