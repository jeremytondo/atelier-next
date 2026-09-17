import AppKit
import ApplicationServices

/// The real Mac.
package struct LiveMac: Mac {
  private let census: WindowCensus

  package init() throws {
    census = WindowCensus(skyLight: try SkyLight())
    // The system-wide element sets the limit for every request this process
    // makes; a limit set on an app's element would not reach its windows.
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), WindowCensus.requestTimeLimit)
  }

  package var hasAccessibility: Bool { Accessibility.isGranted }

  package func requestAccessibility() {
    Accessibility.request()
  }

  package func focus() async -> Focus {
    let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
    return await census.focus(of: app == getpid() ? nil : app)
  }

  package func snapshot() async -> Snapshot? {
    await census.snapshot()
  }
}
