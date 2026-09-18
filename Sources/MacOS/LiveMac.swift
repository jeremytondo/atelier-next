import AppKit
import ApplicationServices
import DesktopBridge

/// The real Mac.
package struct LiveMac: Mac {
  private let skyLight: SkyLight
  private let census: WindowCensus
  private let shortcuts: SpaceShortcuts

  package init() throws {
    skyLight = try SkyLight()
    census = WindowCensus(skyLight: skyLight)
    shortcuts = SpaceShortcuts(skyLight: skyLight)
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

  package func changes() -> AsyncStream<Void> {
    WindowWatcher.changes()
  }

  package func spaces() -> [DisplaySpaces] {
    DisplaySpaces.decode(skyLight.managedDisplaySpaces())
  }

  package func isMissionControlOpen() async -> Bool? {
    await Background.run { MissionControl.isOpen }
  }

  package func switchSpace(to space: UInt64, on display: String, expecting: [DisplaySpaces]) async
    -> SpaceDispatch
  {
    await shortcuts.switchSpace(to: space, on: display, expecting: expecting)
  }

  /// Dock keeps its own list of Desktops, and its shortcuts reach a new one
  /// only once that list has it, so creation waits a moment for Dock.
  package func createDesktop(expecting: [DisplaySpaces]) async -> DesktopCreation {
    let dockCount = skyLight.dockDesktopCount()
    let result = await bridge(expecting: expecting) { DesktopBridge.createDesktop() }
    guard case .sent(let id) = result else { return result.creation }
    let deadline = ContinuousClock.now + .seconds(1)
    while let dockCount, skyLight.dockDesktopCount() == dockCount, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return .created(id)
  }

  package func moveSpace(
    _ id: UInt64, toIndex index: Int, onDisplay display: String, expecting: [DisplaySpaces]
  ) async -> SpaceDispatch {
    guard let index = UInt32(exactly: index) else { return .refused("No such place") }
    return await bridge(expecting: expecting) {
      DesktopBridge.moveSpace(id, to: index, onDisplay: display)
    }.dispatch
  }

  package func destroySpace(_ id: UInt64, expecting: [DisplaySpaces]) async -> SpaceDispatch {
    await bridge(expecting: expecting) { DesktopBridge.destroySpace(id) }.dispatch
  }

  package func raise(window: UInt32, of app: Int32) async -> RaiseResult {
    await census.raise(window: window, of: app)
  }

  private enum BridgeResult {
    case sent(UInt64)
    case changed
    case refused(String)
    case uncertain(String)

    var dispatch: SpaceDispatch {
      switch self {
      case .sent: .sent
      case .changed: .changed
      case .refused(let reason): .refused(reason)
      case .uncertain(let reason): .uncertain(reason)
      }
    }

    var creation: DesktopCreation {
      switch self {
      case .sent(let id): .created(id)
      case .changed: .changed
      case .refused(let reason): .refused(reason)
      case .uncertain(let reason): .uncertain(reason)
      }
    }
  }

  /// Dock registers Desktops made this way only from macOS 27. On macOS 26
  /// WindowServer makes a Desktop that Mission Control never shows.
  ///
  /// The last look at the Spaces and the operation run together on the main
  /// thread, which the operations need anyway, with no pause between them.
  private func bridge(
    expecting: [DisplaySpaces], _ operation: @MainActor @Sendable () -> DesktopBridgeResult
  ) async -> BridgeResult {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
      return .refused("Changing Desktops needs macOS 27.")
    }
    return await MainActor.run {
      guard spaces() == expecting else { return .changed }
      let result = operation()
      return switch result.status {
      case .sent: .sent(result.spaceID)
      case .refused: .refused(result.reason ?? "macOS refused.")
      default: .uncertain(result.reason ?? "macOS gave no reason.")
      }
    }
  }
}
