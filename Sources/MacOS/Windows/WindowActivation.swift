import ApplicationServices
import Carbon

/// Fronts one exact window and makes it key without activating whichever
/// window its app used last. AXRaise alone can change Space but leave the
/// keyboard in another window; app activation can switch to the wrong Space.
/// The caller resolves a live AXWindow before using this, then raises it.
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

  private let getProcess: GetProcess
  private let setFront: SetFront
  private let postRecord: PostRecord
  private typealias SetSpaceFront = @convention(c) (Int32, UInt64, ProcessSerialNumber) -> CGError
  private let setSpaceFront: SetSpaceFront

  init?(skyLight: UnsafeMutableRawPointer, hiServices: UnsafeMutableRawPointer) {
    guard let process = dlsym(hiServices, "GetProcessForPID"),
      let front = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions"),
      let post = dlsym(skyLight, "SLPSPostEventRecordTo"),
      let spaceFront = dlsym(skyLight, "SLSSpaceSetFrontPSN")
    else { return nil }
    getProcess = unsafeBitCast(process, to: GetProcess.self)
    setFront = unsafeBitCast(front, to: SetFront.self)
    postRecord = unsafeBitCast(post, to: PostRecord.self)
    setSpaceFront = unsafeBitCast(spaceFront, to: SetSpaceFront.self)
  }

  func process(for app: pid_t) -> Process? {
    var process = ProcessSerialNumber()
    guard getProcess(app, &process) == 0 else { return nil }
    return Process(app: app, high: process.highLongOfPSN, low: process.lowLongOfPSN)
  }

  func focus(window: UInt32, in target: Process) -> SpaceDispatch {
    guard process(for: target.app) == target else {
      return .refused("The full-screen app is no longer available.")
    }
    var process = target.serial
    guard setFront(&process, window, 0x200) == .success else {
      return .uncertain("macOS could not activate the full-screen window.")
    }

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
    guard postRecord(&process, &record) == .success else {
      return .uncertain("macOS could not give the full-screen window keyboard focus.")
    }
    return .sent
  }

  /// The global front-process call also changes the app remembered by the
  /// origin Space. Restore that record once the origin is offscreen, without
  /// activating the app or changing Spaces again.
  func restoreFront(_ original: Process, space: UInt64, connection: Int32) -> Bool {
    // A terminated or replaced process has no focus record to restore.
    guard process(for: original.app) == original else { return true }
    return setSpaceFront(connection, space, original.serial) == .success
  }
}
