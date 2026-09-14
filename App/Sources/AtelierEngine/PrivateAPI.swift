import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Every private SkyLight and HIServices symbol the helper uses, resolved once
/// per process and handed to the types that need it. Older releases export the
/// Space functions under CGS names, so each one tries both. Construction fails
/// when a symbol every operation depends on is missing; the two that only
/// Desktop creation and All Desktops assignment use stay optional so the rest
/// of the helper keeps working without them.
final class PrivateAPI {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
  private typealias CopySpacesForWindows =
    @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
  private typealias ProcessAssignToAllSpaces = @convention(c) (Int32, pid_t) -> Int32
  private typealias GetSymbolicHotKeyValue =
    @convention(c) (
      UInt32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<CGKeyCode>,
      UnsafeMutablePointer<UInt32>
    ) -> CGError
  private typealias IsSymbolicHotKeyEnabled = @convention(c) (UInt32) -> Bool
  private typealias SetSymbolicHotKeyEnabled = @convention(c) (UInt32, Bool) -> CGError
  private typealias GetWindow =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
  private typealias GetWorkspacesCount =
    @convention(c) (UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Int32

  private let skyLight: UnsafeMutableRawPointer
  private let hiServices: UnsafeMutableRawPointer
  private let connection: Int32
  private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
  private let copySpacesForWindows: CopySpacesForWindows
  private let processAssignToAllSpaces: ProcessAssignToAllSpaces?
  private let getSymbolicHotKeyValue: GetSymbolicHotKeyValue
  private let isSymbolicHotKeyEnabledFunction: IsSymbolicHotKeyEnabled
  private let setSymbolicHotKeyEnabledFunction: SetSymbolicHotKeyEnabled
  private let getWindow: GetWindow
  private let getWorkspacesCount: GetWorkspacesCount?

  init() throws {
    guard
      let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
    else { throw EngineError("Could not open SkyLight.framework") }
    guard
      let hiServices = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices",
        RTLD_LAZY | RTLD_LOCAL)
    else {
      dlclose(skyLight)
      throw EngineError("Could not open HIServices.framework")
    }
    func symbol(_ primary: String, or fallback: String? = nil) -> UnsafeMutableRawPointer? {
      dlsym(skyLight, primary) ?? fallback.flatMap { dlsym(skyLight, $0) }
    }
    guard let main = symbol("SLSMainConnectionID", or: "CGSMainConnectionID"),
      let managed = symbol("SLSCopyManagedDisplaySpaces", or: "CGSCopyManagedDisplaySpaces"),
      let membership = symbol("SLSCopySpacesForWindows", or: "CGSCopySpacesForWindows"),
      let get = symbol("CGSGetSymbolicHotKeyValue"),
      let isEnabled = symbol("CGSIsSymbolicHotKeyEnabled"),
      let setEnabled = symbol("CGSSetSymbolicHotKeyEnabled"),
      let window = dlsym(hiServices, "_AXUIElementGetWindow")
    else {
      dlclose(hiServices)
      dlclose(skyLight)
      throw EngineError(
        "Required SkyLight Space, hotkey, or window identity symbols are unavailable")
    }
    self.skyLight = skyLight
    self.hiServices = hiServices
    connection = unsafeBitCast(main, to: MainConnection.self)()
    copyManagedDisplaySpaces = unsafeBitCast(managed, to: CopyManagedDisplaySpaces.self)
    copySpacesForWindows = unsafeBitCast(membership, to: CopySpacesForWindows.self)
    getSymbolicHotKeyValue = unsafeBitCast(get, to: GetSymbolicHotKeyValue.self)
    isSymbolicHotKeyEnabledFunction = unsafeBitCast(isEnabled, to: IsSymbolicHotKeyEnabled.self)
    setSymbolicHotKeyEnabledFunction = unsafeBitCast(setEnabled, to: SetSymbolicHotKeyEnabled.self)
    getWindow = unsafeBitCast(window, to: GetWindow.self)
    processAssignToAllSpaces = symbol("SLSProcessAssignToAllSpaces").map {
      unsafeBitCast($0, to: ProcessAssignToAllSpaces.self)
    }
    getWorkspacesCount = dlsym(hiServices, "CoreDockGetWorkspacesCount").map {
      unsafeBitCast($0, to: GetWorkspacesCount.self)
    }
  }

  deinit {
    dlclose(hiServices)
    dlclose(skyLight)
  }

  /// The undocumented per-display dictionaries behind SpaceTopology.decode.
  func managedDisplaySpaces() -> [[String: Any]] {
    copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
  }

  /// Managed Space IDs a window belongs to; empty for unknown or hidden windows.
  func spaces(ofWindow id: UInt32) -> [String] {
    let value = copySpacesForWindows(connection, 0x7, [NSNumber(value: id)] as CFArray)?
      .takeRetainedValue()
    return (value as? [NSNumber] ?? []).map(\.stringValue)
  }

  /// The CGWindowID behind an Accessibility window, or 0 when it has none.
  func windowID(of element: AXUIElement) -> UInt32 {
    var id: CGWindowID = 0
    return getWindow(element, &id) == .success ? id : 0
  }

  var canAssignToAllSpaces: Bool { processAssignToAllSpaces != nil }

  /// Session-level All Desktops assignment; the WindowServer result code, or
  /// nil when the symbol is unavailable.
  func assignToAllSpaces(pid: pid_t) -> Int32? {
    processAssignToAllSpaces?(connection, pid)
  }

  func symbolicHotKeyValue(_ id: UInt32) -> (key: CGKeyCode, flags: UInt32)? {
    var key: CGKeyCode = 0
    var flags: UInt32 = 0
    guard getSymbolicHotKeyValue(id, nil, &key, &flags) == .success else { return nil }
    return (key, flags)
  }

  func isSymbolicHotKeyEnabled(_ id: UInt32) -> Bool {
    isSymbolicHotKeyEnabledFunction(id)
  }

  func setSymbolicHotKeyEnabled(_ id: UInt32, _ enabled: Bool) -> Bool {
    setSymbolicHotKeyEnabledFunction(id, enabled) == .success
  }

  var canCountDockDesktops: Bool { getWorkspacesCount != nil }

  /// Dock's own count of ordinary Desktops, independent of WindowServer's
  /// census; nil when the query is unavailable or fails.
  func dockDesktopCount() -> Int? {
    guard let getWorkspacesCount else { return nil }
    var rows: UInt32 = 0
    var columns: UInt32 = 0
    guard getWorkspacesCount(&rows, &columns) == 0 else { return nil }
    return Int(rows) * Int(columns)
  }
}
