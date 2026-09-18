import AppKit

/// Says which modifier keys are held, whenever that changes, through AppKit's
/// event monitors. Listening only: nothing is consumed or delayed. A global
/// monitor sees other apps' events and a local one Atelier's own.
@MainActor
final class ModifierWatcher {
  private var monitors: [Any] = []

  static func changes() -> AsyncStream<Chord.Modifiers> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Chord.Modifiers.self, bufferingPolicy: .bufferingNewest(1))
    let watcher = ModifierWatcher()
    let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
      continuation.yield(Chord.Modifiers(event.modifierFlags))
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
      continuation.yield(Chord.Modifiers(event.modifierFlags))
      return event
    }
    watcher.monitors = [global, local].compactMap { $0 }
    continuation.onTermination = { _ in
      Task { @MainActor in watcher.stop() }
    }
    return stream
  }

  private func stop() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors = []
  }
}

extension Chord.Modifiers {
  package init(_ flags: NSEvent.ModifierFlags) {
    self = []
    if flags.contains(.function) { insert(.function) }
    if flags.contains(.control) { insert(.control) }
    if flags.contains(.option) { insert(.option) }
    if flags.contains(.shift) { insert(.shift) }
    if flags.contains(.command) { insert(.command) }
  }
}
