import ApplicationServices
import CoreGraphics
import Foundation

/// Typed readers and writers over the C Accessibility API. A lookup that fails
/// or times out reads as nil, so an unresponsive app looks like "no window".
extension AXUIElement {
  /// An application element; a short messaging timeout keeps a hung app from
  /// stalling the helper. Pass nil to keep the system default for Dock, whose
  /// replies slow down during Mission Control animations.
  static func application(_ pid: pid_t, timeout: Float? = 0.35) -> AXUIElement {
    let element = AXUIElementCreateApplication(pid)
    if let timeout { AXUIElementSetMessagingTimeout(element, timeout) }
    return element
  }

  func attribute(_ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  func string(_ name: String) -> String? {
    attribute(name) as? String
  }

  func bool(_ name: String) -> Bool? {
    attribute(name) as? Bool
  }

  func element(_ name: String) -> AXUIElement? {
    guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  func elements(_ name: String) -> [AXUIElement] {
    attribute(name) as? [AXUIElement] ?? []
  }

  var children: [AXUIElement] {
    elements(kAXChildrenAttribute)
  }

  /// Position and size in the top-left screen coordinates Accessibility uses.
  var frame: CGRect? {
    guard let positionValue = attribute(kAXPositionAttribute),
      let sizeValue = attribute(kAXSizeAttribute),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
      AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
  }

  func isSettable(_ name: String) -> Bool {
    var settable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(self, name as CFString, &settable)
    return settable.boolValue
  }

  @discardableResult
  func set(_ name: String, _ value: CFTypeRef) -> Bool {
    AXUIElementSetAttributeValue(self, name as CFString, value) == .success
  }

  func set(_ name: String, point: CGPoint) -> Bool {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return false }
    return set(name, value)
  }

  func set(_ name: String, size: CGSize) -> Bool {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return false }
    return set(name, value)
  }

  @discardableResult
  func perform(_ action: String) -> Bool {
    AXUIElementPerformAction(self, action as CFString) == .success
  }

  var actions: [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(self, &names) == .success else { return [] }
    return names as? [String] ?? []
  }

  /// Breadth-first, including the receiver, bounded so a runaway tree cannot
  /// stall the helper.
  func descendants(maximumDepth: Int, limit: Int = 2000) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue: [(AXUIElement, Int)] = [(self, 0)]
    var cursor = 0
    while cursor < queue.count, result.count < limit {
      let (element, depth) = queue[cursor]
      cursor += 1
      result.append(element)
      guard depth < maximumDepth else { continue }
      queue.append(contentsOf: element.children.map { ($0, depth + 1) })
    }
    return result
  }

  func firstDescendant(identifier: String, maximumDepth: Int = 8) -> AXUIElement? {
    descendants(maximumDepth: maximumDepth).first { $0.string("AXIdentifier") == identifier }
  }
}
