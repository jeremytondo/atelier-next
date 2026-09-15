import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension MissionControlSeams {
  /// Dock's Mission Control accessibility tree and synthesized input.
  static func live(runtime: SpaceRuntime, poller: Poller) -> MissionControlSeams {
    MissionControlSeams(
      topology: { runtime.snapshot() },
      postSymbolicHotKey: { runtime.postSymbolicHotKey($0) },
      isVisible: { DockOverview.root() != nil },
      thumbnails: { DockOverview.spaceButtons(on: $0)?.map { $0.frame ?? .null } },
      press: { display, index in
        DockOverview.spaceButtons(on: display)?[safe: index]?.perform(kAXPressAction) == true
      },
      removeDesktop: { display, index in
        DockOverview.spaceButtons(on: display)?[safe: index]?.perform("AXRemoveDesktop") == true
      },
      displayBounds: { CGDisplayBounds($0) },
      pointer: { CGEvent(source: nil)?.location },
      movePointer: { point in
        guard CGWarpMouseCursorPosition(point) == .success,
          let event = CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
            mouseButton: .left)
        else { return false }
        event.post(tap: .cghidEventTap)
        return true
      },
      drag: drag,
      poller: poller)
  }

  /// A left-button drag paced for Dock's drag recognition. The timing between
  /// events is part of the gesture, so this pumps the run loop directly rather
  /// than through the coarser polling interval.
  private static func drag(from source: CGPoint, to destination: CGPoint) -> Bool {
    guard let events = CGEventSource(stateID: .hidSystemState),
      let move = CGEvent(
        mouseEventSource: events, mouseType: .mouseMoved, mouseCursorPosition: source,
        mouseButton: .left),
      let down = CGEvent(
        mouseEventSource: events, mouseType: .leftMouseDown, mouseCursorPosition: source,
        mouseButton: .left),
      let up = CGEvent(
        mouseEventSource: events, mouseType: .leftMouseUp, mouseCursorPosition: destination,
        mouseButton: .left)
    else { return false }
    func pause(_ seconds: TimeInterval) {
      RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    move.post(tap: .cghidEventTap)
    pause(0.08)
    down.post(tap: .cghidEventTap)
    pause(0.12)
    let steps = 10
    for step in 1...steps {
      let progress = CGFloat(step) / CGFloat(steps)
      let point = CGPoint(
        x: source.x + (destination.x - source.x) * progress,
        y: source.y + (destination.y - source.y) * progress)
      guard
        let dragged = CGEvent(
          mouseEventSource: events, mouseType: .leftMouseDragged, mouseCursorPosition: point,
          mouseButton: .left)
      else {
        up.post(tap: .cghidEventTap)
        return false
      }
      dragged.post(tap: .cghidEventTap)
      pause(0.025)
    }
    pause(0.12)
    up.post(tap: .cghidEventTap)
    return true
  }
}

/// Dock's Mission Control tree: an `mc` root, one `mc.display` per display
/// carrying `AXDisplayID`, and an `mc.spaces.list` whose children are the
/// Spaces bar thumbnails in native order.
private enum DockOverview {
  static func root() -> AXUIElement? {
    guard
      let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        .first
    else { return nil }
    return AXUIElement.application(dock.processIdentifier, timeout: nil)
      .firstDescendant(identifier: "mc", maximumDepth: 3)
  }

  static func spaceButtons(on displayID: CGDirectDisplayID) -> [AXUIElement]? {
    guard let root = root(),
      let display = root.descendants(maximumDepth: 4).first(where: {
        $0.string("AXIdentifier") == "mc.display"
          && ($0.attribute("AXDisplayID") as? NSNumber)?.uint32Value == displayID
      }),
      let list = display.firstDescendant(identifier: "mc.spaces.list")
    else { return nil }
    return list.children
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
