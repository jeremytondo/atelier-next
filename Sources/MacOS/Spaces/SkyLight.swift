import ApplicationServices
import Foundation

/// Every private SkyLight and HIServices symbol Atelier uses, resolved once.
/// The libraries stay open for the life of the process.
struct SkyLight: Sendable {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
  private typealias CopySpacesForWindows =
    @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
  private typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
  private typealias GetWindow =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

  private let connection: Int32
  private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
  private let copySpacesForWindows: CopySpacesForWindows
  private let getActiveSpace: GetActiveSpace
  private let getWindow: GetWindow

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
      let window = dlsym(hiServices, "_AXUIElementGetWindow")
    else { throw MacError("The Space and window identity symbols are unavailable") }
    connection = unsafeBitCast(main, to: MainConnection.self)()
    copyManagedDisplaySpaces = unsafeBitCast(managed, to: CopyManagedDisplaySpaces.self)
    copySpacesForWindows = unsafeBitCast(membership, to: CopySpacesForWindows.self)
    getActiveSpace = unsafeBitCast(active, to: GetActiveSpace.self)
    getWindow = unsafeBitCast(window, to: GetWindow.self)
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
}

package struct MacError: Error, CustomStringConvertible {
  package let description: String

  init(_ description: String) {
    self.description = description
  }
}
