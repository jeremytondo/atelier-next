import MacOS

/// The `permissions` subject: what macOS must allow before Atelier can work.
public struct Permissions: Sendable {
  let mac: any Mac

  public var hasAccessibility: Bool { mac.hasAccessibility }

  /// Starts the user on granting Accessibility; macOS finishes it in System
  /// Settings, so ask `hasAccessibility` again afterwards.
  public func requestAccessibility() {
    mac.requestAccessibility()
  }
}
