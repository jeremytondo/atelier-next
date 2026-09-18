import AppKit
import ApplicationServices

/// A window's place and size through Accessibility, in the coordinates
/// Accessibility uses: points from the top-left of the primary display,
/// y growing downwards.
extension WindowCensus {
  func frame(ofWindow id: UInt32, in pid: pid_t) async -> CGRect? {
    await Background.run {
      // Read one at a time: the several-at-once reader takes an AXValue for
      // a missing attribute, and these two are AXValues.
      guard let window = element(ofWindow: id, in: pid),
        let position = window.attribute(kAXPositionAttribute).flatMap(Self.point),
        let size = window.attribute(kAXSizeAttribute).flatMap(Self.size)
      else { return nil }
      return CGRect(origin: position, size: size)
    }
  }

  /// Asks for the size first, then the position, so a window an app keeps
  /// larger than asked still lands where the caller can see it. False when
  /// the window cannot be found; an app that refuses is caught by reading
  /// the frame back.
  func setFrame(_ frame: CGRect, ofWindow id: UInt32, in pid: pid_t) async -> Bool {
    await Background.run {
      guard let window = element(ofWindow: id, in: pid) else { return false }
      var size = frame.size
      var origin = frame.origin
      if let value = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
      }
      if let value = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
      }
      return true
    }
  }

  private func element(ofWindow id: UInt32, in pid: pid_t) -> AXUIElement? {
    (AXUIElementCreateApplication(pid).attribute(kAXWindowsAttribute) as? [AXUIElement])?
      .first { skyLight.windowID(of: $0) == id }
  }

  private static func point(_ value: CFTypeRef) -> CGPoint? {
    var point = CGPoint.zero
    guard CFGetTypeID(value) == AXValueGetTypeID(),
      AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point)
    else { return nil }
    return point
  }

  private static func size(_ value: CFTypeRef) -> CGSize? {
    var size = CGSize.zero
    guard CFGetTypeID(value) == AXValueGetTypeID(),
      AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size)
    else { return nil }
    return size
  }
}

extension NSScreen {
  /// The screen WindowServer calls `identifier`, its display UUID.
  static func named(_ identifier: String) -> NSScreen? {
    screens.first { screen in
      guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
        let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
      else { return false }
      return CFUUIDCreateString(nil, uuid) as String == identifier
    }
  }

  /// The area free of the menu bar and Dock, in Accessibility's coordinates.
  var usableFrame: CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
    let visible = visibleFrame
    return CGRect(
      x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height
    )
  }
}
