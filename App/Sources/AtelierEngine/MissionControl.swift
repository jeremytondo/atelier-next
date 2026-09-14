import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import SpaceControlCore

struct MissionControlError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

final class MissionControlAccessibility {
  private static let missionControlAction: UInt32 = 32
  private static let previousSpaceAction: UInt32 = 79
  private static let nextSpaceAction: UInt32 = 81
  private static let presentationSettleTime: TimeInterval = 0.35
  private static let minimumExpandedThumbnailHeight: CGFloat = 48
  private static let thumbnailSettleTime: TimeInterval = 0.25
  private let runtime: SpaceRuntime
  private var pointerPositionBeforeKeyboardNavigation: CGPoint?
  private var lastSyntheticPointerPosition: CGPoint?

  init(runtime: SpaceRuntime) {
    self.runtime = runtime
  }

  func isVisible() -> Bool {
    missionControlRoot() != nil
  }

  func resetKeyboardNavigation() {
    defer {
      pointerPositionBeforeKeyboardNavigation = nil
      lastSyntheticPointerPosition = nil
    }
    guard let originalPosition = pointerPositionBeforeKeyboardNavigation,
      let syntheticPosition = lastSyntheticPointerPosition,
      let currentPosition = currentPointerPosition(),
      hypot(
        currentPosition.x - syntheticPosition.x,
        currentPosition.y - syntheticPosition.y
      ) <= 6
    else {
      return
    }
    _ = postPointerMove(to: originalPosition)
  }

  func beginKeyboardNavigation(
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard
      let display = topology.first(where: {
        $0.identifier == target.topologyIdentifier
      }),
      let currentIndex = display.regularDesktops.firstIndex(where: {
        $0.id == display.currentSpaceID
      })
    else {
      return .failure(MissionControlError(message: "Could not resolve the current Desktop"))
    }
    // Dock exposes its AX root before the entrance animation finishes. Hovering
    // the top edge during that animation is ignored, so wait before requesting expansion.
    RunLoop.current.run(
      until: Date().addingTimeInterval(Self.presentationSettleTime)
    )
    guard ensureExpandedSpacesBar(on: target, topology: topology) else {
      return .failure(
        MissionControlError(message: "The native Spaces bar did not expand"))
    }
    return .success(currentIndex + 1)
  }

  func activateAdjacentDesktop(
    offset: Int,
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard isVisible() else {
      return .failure(MissionControlError(message: "Mission Control is no longer open"))
    }
    guard let (display, currentIndex) = activeDesktop(on: target, topology: topology) else {
      return .failure(MissionControlError(message: "No ordinary Desktop is currently active"))
    }
    let desktops = display.regularDesktops
    let nextIndex = min(max(currentIndex + offset, 0), desktops.count - 1)
    guard nextIndex != currentIndex else { return .success(currentIndex + 1) }

    let current = desktops[currentIndex]
    let destination = desktops[nextIndex]
    guard let currentFullIndex = display.spaces.firstIndex(where: { $0.id == current.id }),
      let destinationFullIndex = display.spaces.firstIndex(where: { $0.id == destination.id })
    else {
      return .failure(
        MissionControlError(message: "Could not resolve the adjacent Desktop route"))
    }

    let action = offset < 0 ? Self.previousSpaceAction : Self.nextSpaceAction
    let step = offset < 0 ? -1 : 1
    for fullIndex in stride(
      from: currentFullIndex + step,
      through: destinationFullIndex,
      by: step
    ) {
      let expectedSpace = display.spaces[fullIndex]
      guard runtime.postSymbolicHotKey(action),
        waitForCurrentSpace(
          expectedSpace.id,
          on: target.topologyIdentifier,
          timeout: 3
        ),
        waitForMissionControlRoot(timeout: 2) != nil
      else {
        return .failure(
          MissionControlError(
            message:
              "macOS did not keep Mission Control open while activating Desktop \(nextIndex + 1)"
          ))
      }
    }

    let updatedTopology = runtime.snapshot()
    guard
      updatedTopology.first(where: {
        $0.identifier == target.topologyIdentifier
      })?.currentSpaceID == destination.id,
      ensureExpandedSpacesBar(on: target, topology: updatedTopology)
    else {
      return .failure(
        MissionControlError(message: "The active Desktop thumbnail did not remain expanded"))
    }
    return .success(nextIndex + 1)
  }

  func enterActiveDesktop(
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard isVisible() else {
      return .failure(MissionControlError(message: "Mission Control is no longer open"))
    }
    guard let (display, activeIndex) = activeDesktop(on: target, topology: topology) else {
      return .failure(MissionControlError(message: "No ordinary Desktop is currently active"))
    }
    let active = display.regularDesktops[activeIndex]
    guard let fullIndex = display.spaces.firstIndex(where: { $0.id == active.id }),
      let button = waitForExpandedSpaceButton(
        displayID: target.displayID,
        index: fullIndex,
        expectedCount: display.spaces.count,
        timeout: 2
      )
    else {
      return .failure(
        MissionControlError(message: "Could not resolve the active Desktop thumbnail"))
    }
    guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
      return .failure(
        MissionControlError(message: "The active Desktop rejected selection"))
    }
    guard waitForMissionControlToClose(timeout: 3) || closeMissionControl(timeout: 2) else {
      return .failure(
        MissionControlError(message: "Mission Control did not close after entering the Desktop"))
    }
    guard currentSpaceID(on: target.topologyIdentifier) == active.id else {
      return .failure(
        MissionControlError(message: "The active Desktop changed while Mission Control closed"))
    }
    return .success(activeIndex + 1)
  }

  func reorderActiveDesktop(
    offset: Int,
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard isVisible() else {
      return .failure(MissionControlError(message: "Mission Control is no longer open"))
    }
    guard let (display, sourceIndex) = activeDesktop(on: target, topology: topology) else {
      return .failure(MissionControlError(message: "No ordinary Desktop is currently active"))
    }
    let desktops = display.regularDesktops
    let destinationIndex = sourceIndex + offset
    guard desktops.indices.contains(destinationIndex) else {
      return .success(sourceIndex + 1)
    }

    let active = desktops[sourceIndex]
    let destination = desktops[destinationIndex]
    guard let sourceFullIndex = display.spaces.firstIndex(where: { $0.id == active.id }),
      let destinationFullIndex = display.spaces.firstIndex(where: { $0.id == destination.id }),
      let sourceButton = spaceButton(
        displayID: target.displayID,
        index: sourceFullIndex,
        expectedCount: display.spaces.count
      ),
      let destinationButton = spaceButton(
        displayID: target.displayID,
        index: destinationFullIndex,
        expectedCount: display.spaces.count
      ),
      let sourceFrame = frame(of: sourceButton),
      let destinationFrame = frame(of: destinationButton)
    else {
      return .failure(
        MissionControlError(message: "Could not resolve the active Desktop thumbnails"))
    }

    let destinationPoint = CGPoint(
      x: offset < 0 ? destinationFrame.minX + 4 : destinationFrame.maxX - 4,
      y: destinationFrame.midY
    )
    // Dock preserves the grab offset inside the thumbnail. Match the left-edge
    // insertion target with a left-edge grab; a center grab can skip a slot or
    // drop back into the original position.
    let sourcePoint = CGPoint(x: sourceFrame.minX + 4, y: sourceFrame.midY)
    guard drag(from: sourcePoint, to: destinationPoint) else {
      return .failure(MissionControlError(message: "Could not synthesize the Desktop drag"))
    }

    guard
      waitUntil(
        timeout: 3,
        condition: {
          let snapshot = self.runtime.snapshot()
          guard
            let updatedDisplay = snapshot.first(where: {
              $0.identifier == target.topologyIdentifier
            }),
            updatedDisplay.regularDesktops.firstIndex(where: { $0.id == active.id })
              == destinationIndex
          else {
            return false
          }
          return true
        })
    else {
      return .failure(
        MissionControlError(message: "macOS did not confirm the Desktop reorder"))
    }

    guard ensureExpandedSpacesBar(on: target, topology: runtime.snapshot()) else {
      return .failure(
        MissionControlError(message: "The reordered Desktop thumbnail did not remain expanded"))
    }
    return .success(destinationIndex + 1)
  }

  func deleteActiveDesktop(
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard isVisible() else {
      return .failure(MissionControlError(message: "Mission Control is no longer open"))
    }
    guard let (display, activeIndex) = activeDesktop(on: target, topology: topology) else {
      return .failure(MissionControlError(message: "No ordinary Desktop is currently active"))
    }
    let desktops = display.regularDesktops
    guard desktops.count > 1 else {
      return .failure(MissionControlError(message: "The final Desktop cannot be deleted"))
    }
    let desktopToDelete = desktops[activeIndex]
    let neighborOffset = activeIndex < desktops.count - 1 ? 1 : -1
    let neighborIndex = activeIndex + neighborOffset
    let neighbor = desktops[neighborIndex]

    switch activateAdjacentDesktop(offset: neighborOffset, on: target, topology: topology) {
    case .failure(let error):
      return .failure(
        MissionControlError(
          message: "Could not leave the active Desktop before deletion: \(error.message)"))
    case .success:
      break
    }

    guard
      let afterActivation = runtime.snapshot().first(where: {
        $0.identifier == target.topologyIdentifier
      }), afterActivation.currentSpaceID == neighbor.id,
      let fullIndex = afterActivation.spaces.firstIndex(where: { $0.id == desktopToDelete.id }),
      let button = waitForStableSpaceButton(
        displayID: target.displayID,
        index: fullIndex,
        expectedCount: afterActivation.spaces.count,
        timeout: 2
      )
    else {
      return .failure(
        MissionControlError(message: "Could not resolve the former active Desktop thumbnail"))
    }
    guard AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString) == .success else {
      return .failure(
        MissionControlError(message: "Desktop \(activeIndex + 1) rejected deletion"))
    }

    var updatedDisplay: DisplaySpaceSnapshot?
    guard
      waitUntil(
        timeout: 3,
        condition: {
          guard
            let candidate = self.runtime.snapshot().first(where: {
              $0.identifier == target.topologyIdentifier
            }), !candidate.spaces.contains(where: { $0.id == desktopToDelete.id })
          else {
            return false
          }
          updatedDisplay = candidate
          return true
        }), let updatedDisplay
    else {
      return .failure(MissionControlError(message: "macOS did not confirm Desktop deletion"))
    }

    guard updatedDisplay.currentSpaceID == neighbor.id else {
      return .failure(
        MissionControlError(message: "The neighboring Desktop did not remain active"))
    }
    guard ensureExpandedSpacesBar(on: target, topology: [updatedDisplay]) else {
      return .failure(
        MissionControlError(message: "The neighboring Desktop thumbnail did not remain expanded"))
    }
    return .success(activeIndex + 1)
  }

  private func activeDesktop(
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> (DisplaySpaceSnapshot, Int)? {
    guard
      let display = topology.first(where: {
        $0.identifier == target.topologyIdentifier
      }), !display.regularDesktops.isEmpty
    else {
      return nil
    }
    guard
      let index = display.regularDesktops.firstIndex(where: {
        $0.id == display.currentSpaceID
      })
    else {
      return nil
    }
    return (display, index)
  }

  private func spaceButton(
    displayID: CGDirectDisplayID,
    index: Int,
    expectedCount: Int
  ) -> AXUIElement? {
    guard let root = missionControlRoot(),
      let display = missionControlDisplay(in: root, displayID: displayID),
      let list = firstDescendant(of: display, identifier: "mc.spaces.list"),
      let children = copyAXAttribute(list, kAXChildrenAttribute) as? [AXUIElement],
      children.count == expectedCount,
      children.indices.contains(index)
    else {
      return nil
    }
    return children[index]
  }

  private func frame(of element: AXUIElement) -> CGRect? {
    guard let positionValue = copyAXAttribute(element, kAXPositionAttribute),
      let sizeValue = copyAXAttribute(element, kAXSizeAttribute),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
      AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
    else {
      return nil
    }
    return CGRect(origin: position, size: size)
  }

  private func ensureExpandedSpacesBar(
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Bool {
    guard
      let display = topology.first(where: {
        $0.identifier == target.topologyIdentifier
      }),
      let currentFullIndex = display.spaces.firstIndex(where: {
        $0.id == display.currentSpaceID
      }),
      expandSpacesBar(on: target.displayID)
    else {
      return false
    }
    return waitForExpandedSpaceButton(
      displayID: target.displayID,
      index: currentFullIndex,
      expectedCount: display.spaces.count,
      timeout: 2
    ) != nil
  }

  private func expandSpacesBar(on displayID: CGDirectDisplayID) -> Bool {
    let bounds = CGDisplayBounds(displayID)
    guard !bounds.isNull, bounds.width > 2, bounds.height > 2 else { return false }
    let currentX = currentPointerPosition()?.x ?? bounds.midX
    let point = CGPoint(
      x: min(max(currentX, bounds.minX + 1), bounds.maxX - 1),
      y: bounds.minY + 1
    )
    return movePointer(to: point)
  }

  private func movePointer(to point: CGPoint) -> Bool {
    if pointerPositionBeforeKeyboardNavigation == nil {
      pointerPositionBeforeKeyboardNavigation = currentPointerPosition()
    }
    guard postPointerMove(to: point) else { return false }
    lastSyntheticPointerPosition = point
    return true
  }

  private func postPointerMove(to point: CGPoint) -> Bool {
    guard CGWarpMouseCursorPosition(point) == .success,
      let event = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
      )
    else {
      return false
    }
    event.post(tap: .cghidEventTap)
    return true
  }

  private func currentPointerPosition() -> CGPoint? {
    CGEvent(source: nil)?.location
  }

  private func drag(from sourcePoint: CGPoint, to destinationPoint: CGPoint) -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState),
      let move = CGEvent(
        mouseEventSource: source,
        mouseType: .mouseMoved,
        mouseCursorPosition: sourcePoint,
        mouseButton: .left
      ),
      let down = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseDown,
        mouseCursorPosition: sourcePoint,
        mouseButton: .left
      ),
      let up = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseUp,
        mouseCursorPosition: destinationPoint,
        mouseButton: .left
      )
    else {
      return false
    }

    move.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    down.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.12))

    let steps = 10
    for step in 1...steps {
      let progress = CGFloat(step) / CGFloat(steps)
      let point = CGPoint(
        x: sourcePoint.x + (destinationPoint.x - sourcePoint.x) * progress,
        y: sourcePoint.y + (destinationPoint.y - sourcePoint.y) * progress
      )
      guard
        let dragged = CGEvent(
          mouseEventSource: source,
          mouseType: .leftMouseDragged,
          mouseCursorPosition: point,
          mouseButton: .left
        )
      else {
        up.post(tap: .cghidEventTap)
        return false
      }
      dragged.post(tap: .cghidEventTap)
      RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    up.post(tap: .cghidEventTap)
    return true
  }

  private func waitForMissionControlRoot(timeout: TimeInterval) -> AXUIElement? {
    var result: AXUIElement?
    _ = waitUntil(timeout: timeout) {
      result = self.missionControlRoot()
      return result != nil
    }
    return result
  }

  private func missionControlRoot() -> AXUIElement? {
    guard
      let dock = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).first
    else {
      return nil
    }
    let root = AXUIElementCreateApplication(dock.processIdentifier)
    return firstDescendant(of: root, identifier: "mc", maximumDepth: 3)
  }

  private func waitForStableSpaceButton(
    displayID: CGDirectDisplayID,
    index: Int,
    expectedCount: Int,
    timeout: TimeInterval
  ) -> AXUIElement? {
    var candidate: AXUIElement?
    var readySince: Date?
    _ = waitUntil(timeout: timeout) {
      guard
        let button = self.spaceButton(
          displayID: displayID,
          index: index,
          expectedCount: expectedCount
        )
      else {
        candidate = nil
        readySince = nil
        return false
      }
      candidate = button
      if let readySince {
        return Date().timeIntervalSince(readySince) >= Self.thumbnailSettleTime
      }
      readySince = Date()
      return false
    }
    return candidate
  }

  private func waitForExpandedSpaceButton(
    displayID: CGDirectDisplayID,
    index: Int,
    expectedCount: Int,
    timeout: TimeInterval
  ) -> AXUIElement? {
    var candidate: AXUIElement?
    var stableFrame: CGRect?
    var stableSince: Date?
    let completed = waitUntil(timeout: timeout) {
      guard
        let button = self.spaceButton(
          displayID: displayID,
          index: index,
          expectedCount: expectedCount
        ),
        let frame = self.frame(of: button),
        frame.height >= Self.minimumExpandedThumbnailHeight
      else {
        candidate = nil
        stableFrame = nil
        stableSince = nil
        return false
      }
      candidate = button
      if let previousFrame = stableFrame,
        abs(previousFrame.minX - frame.minX) <= 1,
        abs(previousFrame.minY - frame.minY) <= 1,
        abs(previousFrame.width - frame.width) <= 1,
        abs(previousFrame.height - frame.height) <= 1
      {
        if let stableSince {
          return Date().timeIntervalSince(stableSince) >= Self.thumbnailSettleTime
        }
      } else {
        stableFrame = frame
        stableSince = Date()
      }
      return false
    }
    return completed ? candidate : nil
  }

  private func missionControlDisplay(
    in root: AXUIElement,
    displayID: CGDirectDisplayID
  ) -> AXUIElement? {
    descendants(of: root, maximumDepth: 4).first { element in
      guard attributeString(element, "AXIdentifier") == "mc.display",
        let value = copyAXAttribute(element, "AXDisplayID") as? NSNumber
      else {
        return false
      }
      return value.uint32Value == displayID
    }
  }

  private func firstDescendant(
    of root: AXUIElement,
    identifier: String,
    maximumDepth: Int = 8
  ) -> AXUIElement? {
    descendants(of: root, maximumDepth: maximumDepth).first {
      attributeString($0, "AXIdentifier") == identifier
    }
  }

  private func descendants(of root: AXUIElement, maximumDepth: Int) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var cursor = 0
    while cursor < queue.count, result.count < 2_000 {
      let (element, depth) = queue[cursor]
      cursor += 1
      result.append(element)
      guard depth < maximumDepth,
        let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
      else {
        continue
      }
      queue.append(contentsOf: children.map { ($0, depth + 1) })
    }
    return result
  }

  private func attributeString(_ element: AXUIElement, _ attribute: String) -> String? {
    copyAXAttribute(element, attribute) as? String
  }

  private func currentSpaceID(on displayIdentifier: String) -> UInt64? {
    runtime.snapshot().first {
      $0.identifier == displayIdentifier
    }?.currentSpaceID
  }

  private func waitForCurrentSpace(
    _ spaceID: UInt64,
    on displayIdentifier: String,
    timeout: TimeInterval
  ) -> Bool {
    waitUntil(timeout: timeout) {
      self.currentSpaceID(on: displayIdentifier) == spaceID
    }
  }

  private func closeMissionControl(timeout: TimeInterval) -> Bool {
    guard waitForMissionControlRoot(timeout: 0.1) != nil else { return true }
    guard runtime.postSymbolicHotKey(Self.missionControlAction) else { return false }
    return waitForMissionControlToClose(timeout: timeout)
  }

  private func waitForMissionControlToClose(timeout: TimeInterval) -> Bool {
    var absentSince: Date?
    return waitUntil(timeout: timeout) {
      if self.waitForMissionControlRoot(timeout: 0.05) != nil {
        absentSince = nil
        return false
      }
      if let absentAt = absentSince {
        return Date().timeIntervalSince(absentAt) >= 0.2
      }
      absentSince = Date()
      return false
    }
  }

  private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return condition()
  }
}
