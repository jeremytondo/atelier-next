import ApplicationServices
import Carbon
import Foundation

/// Fronts one exact window and makes it key without activating whichever
/// window its app used last. AXRaise alone can change Space but leave the
/// keyboard in another window; app activation can switch to the wrong Space.
/// The caller resolves a live AXWindow before using this, then raises it.
///
/// Nil when macOS lacks any of these symbols: they are apart from `SkyLight`'s
/// own so that losing them costs this and nothing else.
struct WindowActivation: Sendable {
  /// Process serial numbers identify a particular launch even when AppKit
  /// has no launchDate, as happens for Finder on an empty Desktop.
  struct Process: Sendable, Equatable {
    let app: pid_t
    fileprivate let high: UInt32
    fileprivate let low: UInt32

    fileprivate var serial: ProcessSerialNumber {
      ProcessSerialNumber(highLongOfPSN: high, lowLongOfPSN: low)
    }
  }

  private typealias GetProcess =
    @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
  private typealias SetFront =
    @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
  private typealias PostRecord =
    @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) ->
    CGError
  private typealias SetSpaceFront = @convention(c) (Int32, UInt64, ProcessSerialNumber) -> CGError
  private typealias CreateRemoteElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

  private let connection: Int32
  private let getProcess: GetProcess
  private let setFront: SetFront
  private let postRecord: PostRecord
  private let setSpaceFront: SetSpaceFront
  private let createRemoteElement: CreateRemoteElement

  init?(skyLight: UnsafeMutableRawPointer, hiServices: UnsafeMutableRawPointer, connection: Int32) {
    guard let process = dlsym(hiServices, "GetProcessForPID"),
      let front = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions"),
      let post = dlsym(skyLight, "SLPSPostEventRecordTo"),
      let spaceFront = dlsym(skyLight, "SLSSpaceSetFrontPSN"),
      let remoteElement = dlsym(hiServices, "_AXUIElementCreateWithRemoteToken")
    else { return nil }
    self.connection = connection
    getProcess = unsafeBitCast(process, to: GetProcess.self)
    setFront = unsafeBitCast(front, to: SetFront.self)
    postRecord = unsafeBitCast(post, to: PostRecord.self)
    setSpaceFront = unsafeBitCast(spaceFront, to: SetSpaceFront.self)
    createRemoteElement = unsafeBitCast(remoteElement, to: CreateRemoteElement.self)
  }

  func process(for app: pid_t) -> Process? {
    var process = ProcessSerialNumber()
    guard getProcess(app, &process) == 0 else { return nil }
    return Process(app: app, high: process.highLongOfPSN, low: process.lowLongOfPSN)
  }

  /// An app-local Accessibility element number, not a WindowServer window ID.
  /// Off-Space windows are omitted from AXWindows but can still have live
  /// elements. Callers must verify both the window ID and the AXWindow role:
  /// descendants report the same window ID as their containing window.
  func remoteElement(in app: pid_t, number: UInt64) -> AXUIElement? {
    var token = Data()
    withUnsafeBytes(of: app) { token.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(0)) { token.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(0x636f_636f)) { token.append(contentsOf: $0) }
    withUnsafeBytes(of: number) { token.append(contentsOf: $0) }
    return createRemoteElement(token as CFData)?.takeRetainedValue()
  }

  /// False when macOS would not front the window, so nothing was asked of it.
  func focus(window: UInt32, in target: Process) -> Bool {
    var process = target.serial
    guard setFront(&process, window, 0x200) == .success else { return false }

    // WindowServer's event record addresses the window by ID. The mouse-down
    // makes it key; its location is far outside the content so it cannot
    // click a control or resize from a corner. It does not move the pointer.
    var record = [UInt8](repeating: 0, count: 256)
    record[4] = 0xf8
    record[8] = 1
    record[0x3a] = 0x10
    withUnsafeBytes(of: window) { record.replaceSubrange(0x3c..<0x40, with: $0) }
    withUnsafeBytes(of: CGPoint(x: 300_000, y: 300_000)) {
      record.replaceSubrange(0x20..<0x30, with: $0)
    }
    // The window is fronted whatever becomes of the record, so the caller
    // raises it and watches the focus either way.
    _ = postRecord(&process, &record)
    return true
  }

  /// The global front-process call also changes the app remembered by the
  /// origin Space. Restore that record once the origin is offscreen, without
  /// activating the app or changing Spaces again.
  func restoreFront(_ original: Process, space: UInt64) -> Bool {
    // A terminated or replaced process has no focus record to restore.
    guard process(for: original.app) == original else { return true }
    return setSpaceFront(connection, space, original.serial) == .success
  }
}
