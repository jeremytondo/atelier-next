import ApplicationServices
import Foundation

/// Every private SkyLight and HIServices symbol Atelier needs, resolved once;
/// those it can do without are `WindowActivation`'s. The libraries stay open
/// for the life of the process.
struct SkyLight: Sendable {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
  private typealias CopySpacesForWindows =
    @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
  private typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
  private typealias GetWindow =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
  private typealias GetSymbolicHotKeyValue =
    @convention(c) (
      UInt32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<CGKeyCode>,
      UnsafeMutablePointer<UInt32>
    ) -> CGError
  private typealias IsSymbolicHotKeyEnabled = @convention(c) (UInt32) -> Bool
  private typealias SetSymbolicHotKeyEnabled = @convention(c) (UInt32, Bool) -> CGError
  private typealias GetWorkspacesCount =
    @convention(c) (UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Int32

  private let connection: Int32
  private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
  private let copySpacesForWindows: CopySpacesForWindows
  private let getActiveSpace: GetActiveSpace
  private let getWindow: GetWindow
  private let getSymbolicHotKeyValue: GetSymbolicHotKeyValue
  private let hotKeyIsEnabled: IsSymbolicHotKeyEnabled
  private let enableHotKey: SetSymbolicHotKeyEnabled
  private let getWorkspacesCount: GetWorkspacesCount
  let windowActivation: WindowActivation?

  init() throws {
    guard
      let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL),
      let hiServices = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        RTLD_LAZY | RTLD_LOCAL)
    else { throw MacError("Could not open SkyLight or HIServices") }
    guard let main = dlsym(skyLight, "SLSMainConnectionID"),
      let managed = dlsym(skyLight, "SLSCopyManagedDisplaySpaces"),
      let membership = dlsym(skyLight, "SLSCopySpacesForWindows"),
      let active = dlsym(skyLight, "SLSGetActiveSpace"),
      let window = dlsym(hiServices, "_AXUIElementGetWindow"),
      let hotKeyValue = dlsym(skyLight, "CGSGetSymbolicHotKeyValue"),
      let hotKeyEnabled = dlsym(skyLight, "CGSIsSymbolicHotKeyEnabled"),
      let enableHotKey = dlsym(skyLight, "CGSSetSymbolicHotKeyEnabled"),
      let workspaces = dlsym(hiServices, "CoreDockGetWorkspacesCount")
    else { throw MacError("The Space, shortcut, and window identity symbols are unavailable") }
    connection = unsafeBitCast(main, to: MainConnection.self)()
    copyManagedDisplaySpaces = unsafeBitCast(managed, to: CopyManagedDisplaySpaces.self)
    copySpacesForWindows = unsafeBitCast(membership, to: CopySpacesForWindows.self)
    getActiveSpace = unsafeBitCast(active, to: GetActiveSpace.self)
    getWindow = unsafeBitCast(window, to: GetWindow.self)
    getSymbolicHotKeyValue = unsafeBitCast(hotKeyValue, to: GetSymbolicHotKeyValue.self)
    hotKeyIsEnabled = unsafeBitCast(hotKeyEnabled, to: IsSymbolicHotKeyEnabled.self)
    self.enableHotKey = unsafeBitCast(enableHotKey, to: SetSymbolicHotKeyEnabled.self)
    getWorkspacesCount = unsafeBitCast(workspaces, to: GetWorkspacesCount.self)
    // Optional: losing direct full-screen focus must not disable Desktops or
    // make us fall back to a route through some other Space.
    windowActivation = WindowActivation(
      skyLight: skyLight, hiServices: hiServices, connection: connection)
  }

  /// The undocumented per-display dictionaries behind `DisplaySpaces.decode`.
  func managedDisplaySpaces() -> [[String: Any]] {
    copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
  }

  /// Space IDs a window belongs to; empty when WindowServer reports none.
  func spaces(ofWindow id: UInt32) -> [UInt64] {
    let value = copySpacesForWindows(connection, 0x7, [NSNumber(value: id)] as CFArray)?
      .takeRetainedValue()
    return (value as? [NSNumber] ?? []).map(\.uint64Value)
  }

  func activeSpace() -> UInt64 {
    getActiveSpace(connection)
  }

  /// The CGWindowID behind an Accessibility window, or nil when it has none.
  func windowID(of element: AXUIElement) -> UInt32? {
    var id: CGWindowID = 0
    return getWindow(element, &id) == .success && id != 0 ? id : nil
  }

  /// The keys of one of macOS's own keyboard shortcuts, by its number in the
  /// symbolic hotkey table.
  func symbolicHotKey(_ id: UInt32) -> (key: CGKeyCode, flags: UInt32)? {
    var key: CGKeyCode = 0
    var flags: UInt32 = 0
    guard getSymbolicHotKeyValue(id, nil, &key, &flags) == .success else { return nil }
    return (key, flags)
  }

  func isSymbolicHotKeyEnabled(_ id: UInt32) -> Bool {
    hotKeyIsEnabled(id)
  }

  /// Turns a shortcut on or off for this login session only; the user's saved
  /// setting is untouched.
  func setSymbolicHotKey(_ id: UInt32, enabled: Bool) -> Bool {
    enableHotKey(id, enabled) == .success
  }

  /// Dock's own count of Desktops, kept apart from WindowServer's census.
  func dockDesktopCount() -> Int? {
    var rows: UInt32 = 0
    var columns: UInt32 = 0
    guard getWorkspacesCount(&rows, &columns) == 0 else { return nil }
    return Int(rows) * Int(columns)
  }
}

package struct MacError: Error, CustomStringConvertible {
  package let description: String

  init(_ description: String) {
    self.description = description
  }
}
