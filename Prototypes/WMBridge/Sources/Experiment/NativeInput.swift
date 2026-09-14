// A short, read-only trace of Dock's system-defined events during an explicitly
// scripted native shortcut. It never records character input or changes events.
import AppKit
import Trial

private final class DockInputTrace {
  var events: [[String: Any]] = []
  var tap: CFMachPort?
  var source: CFRunLoopSource?
  deinit {
    if let tap { CFMachPortInvalidate(tap) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
  }
}
private var dockInputTrace: DockInputTrace?

func startDockInputTrace() throws -> [String: Any] {
  guard dockInputTrace == nil, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    throw TrialError("Dock unavailable or input trace already running")
  }
  let trace = DockInputTrace()
  let tap = CGEvent.tapCreateForPid(pid: dock.processIdentifier, place: .headInsertEventTap,
    options: .listenOnly, eventsOfInterest: CGEventMask(1 << 14), callback: { _, type, event, context in
      if type.rawValue == 14, let context, let native = NSEvent(cgEvent: event) {
        let trace = Unmanaged<DockInputTrace>.fromOpaque(context).takeUnretainedValue()
        if trace.events.count < 16 {
          trace.events.append(["type": type.rawValue, "subtype": native.subtype.rawValue,
            "data1": native.data1, "data2": native.data2, "flags": event.flags.rawValue])
        }
      }
      return Unmanaged.passUnretained(event)
    }, userInfo: Unmanaged.passUnretained(trace).toOpaque())
  guard let tap else { throw TrialError("Dock system-event trace unavailable with existing permissions") }
  trace.tap = tap
  trace.source = CFMachPortCreateRunLoopSource(nil, tap, 0)
  CFRunLoopAddSource(CFRunLoopGetMain(), trace.source, .commonModes)
  CGEvent.tapEnable(tap: tap, enable: true)
  dockInputTrace = trace
  DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak trace] in
    if let tap = trace?.tap { CFMachPortInvalidate(tap) }
  }
  return ["dockPID": dock.processIdentifier, "observingSystemDefinedOnly": true]
}

func stopDockInputTrace() -> [String: Any] {
  let events = dockInputTrace?.events ?? []
  dockInputTrace = nil
  return ["events": events]
}
