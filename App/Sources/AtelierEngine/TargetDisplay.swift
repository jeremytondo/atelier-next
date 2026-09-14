import AppKit
import ApplicationServices
import CoreGraphics
import SpaceControlCore

struct TargetDisplay {
  let displayID: CGDirectDisplayID
  let topologyIdentifier: String
}

/// The focused window's display, falling back to the pointer's display.
final class TargetDisplayResolver {
  func resolve(in topology: [DisplaySpaceSnapshot]) -> TargetDisplay? {
    if let displayID = focusedWindowDisplayID(),
      let identifier = topologyIdentifier(for: displayID, in: topology)
    {
      return TargetDisplay(displayID: displayID, topologyIdentifier: identifier)
    }
    return pointerDisplay(in: topology)
  }

  private func pointerDisplay(in topology: [DisplaySpaceSnapshot]) -> TargetDisplay? {
    guard let point = CGEvent(source: nil)?.location,
      let displayID = displayID(containing: point),
      let identifier = topologyIdentifier(for: displayID, in: topology)
    else {
      return nil
    }
    return TargetDisplay(displayID: displayID, topologyIdentifier: identifier)
  }

  private func focusedWindowDisplayID() -> CGDirectDisplayID? {
    guard let application = NSWorkspace.shared.frontmostApplication,
      let frame = AXUIElement.application(application.processIdentifier)
        .element(kAXFocusedWindowAttribute)?.frame
    else {
      return nil
    }
    return displayID(containing: frame)
  }

  private func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
    var display: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else {
      return nil
    }
    return display
  }

  private func displayID(containing rect: CGRect) -> CGDirectDisplayID? {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetDisplaysWithRect(rect, UInt32(displays.count), &displays, &count) == .success,
      count > 0
    else {
      return nil
    }
    return displays.prefix(Int(count)).max {
      CGDisplayBounds($0).intersection(rect).area < CGDisplayBounds($1).intersection(rect).area
    }
  }

  private func topologyIdentifier(
    for displayID: CGDirectDisplayID,
    in topology: [DisplaySpaceSnapshot]
  ) -> String? {
    if displayID == CGMainDisplayID(), topology.contains(where: { $0.identifier == "Main" }) {
      return "Main"
    }
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
      let string = CFUUIDCreateString(nil, uuid)
    else {
      return nil
    }
    let identifier = (string as String).uppercased()
    return topology.first { $0.identifier.uppercased() == identifier }?.identifier
  }
}

extension CGRect {
  fileprivate var area: CGFloat { isNull ? 0 : width * height }
}
