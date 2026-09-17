import ApplicationServices

/// Typed readers over the C Accessibility API. A read that fails or times out
/// is nil, so an app that does not answer looks like an app with no windows.
extension AXUIElement {
  func attribute(_ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  func element(_ name: String) -> AXUIElement? {
    guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  /// Several attributes in one request; a missing one is nil in its place.
  func attributes(_ names: [String]) -> [CFTypeRef?]? {
    var values: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(self, names as CFArray, [], &values) == .success,
      let values = values as? [CFTypeRef], values.count == names.count
    else { return nil }
    // A missing attribute arrives as an AXValue holding the error.
    return values.map { CFGetTypeID($0) == AXValueGetTypeID() ? nil : $0 }
  }

  func isSettable(_ name: String) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success
      && settable.boolValue
  }
}
