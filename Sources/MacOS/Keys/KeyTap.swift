import AppKit
import CoreGraphics
import Foundation

/// What the keyboard and mouse did while a key listener was on.
package enum KeyEvent: Sendable, Equatable {
  /// A key went down, with the modifiers held at that moment. Fn is left
  /// out: macOS sets it on arrow keys by itself.
  case keyDown(Chord)
  case flagsChanged(Chord.Modifiers)
  case mouseDown
  /// Another app became frontmost.
  case appSwitched
}

package enum KeyDecision: Sendable {
  /// The event goes no further; no app sees it.
  case consume
  case pass
}

/// A key listener for as long as it is wanted; `stop` ends it.
package protocol KeyListening: Sendable {
  func stop()
}

/// The mark Atelier puts on keystrokes it posts itself, so that a listener
/// of its own lets them through to macOS.
package enum PostedKeys {
  package static let marker: Int64 = 0x4154_4C52  // "ATLR"

  package static func mark(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: marker)
  }
}

/// An event tap that consumes keys on request. It exists only while a
/// listener is wanted, on a thread of its own so that a busy main thread
/// never delays a decision; `decide` runs on that thread and must be quick.
/// A key-up is consumed exactly when its key-down was, so a consumed key
/// reaches no app at all, while the leader's own key, pressed before the
/// tap existed, is released as far as Carbon knows; a stopped tap lingers
/// until the keys it consumed are released. Keystrokes Atelier posted pass
/// untouched.
///
/// The tap is made, used, and taken down on its own thread only; `stop`
/// asks that thread, so no callback can run against a tap being invalidated.
final class KeyTap: KeyListening, @unchecked Sendable {
  private let decide: @Sendable (KeyEvent) -> KeyDecision
  private let codes: KeyCodes
  /// Touched only on the tap's thread once it runs.
  private var tap: CFMachPort?
  private var consumedDowns: Set<CGKeyCode> = []
  /// Set once `stop` was asked; the tap lingers until the consumed keys are
  /// released, so their key-ups reach no app either, or a moment at most.
  private var isStopping = false
  private var thread: Thread?
  private var runLoop: CFRunLoop?
  private var activation: (any NSObjectProtocol)?

  /// Nil when macOS refuses the tap, which it does without the
  /// Accessibility permission. `codes` is read on the main thread.
  @MainActor static func start(
    codes: KeyCodes, decide: @escaping @Sendable (KeyEvent) -> KeyDecision
  ) -> KeyTap? {
    let listener = KeyTap(codes: codes, decide: decide)
    return listener.begin() ? listener : nil
  }

  private init(codes: KeyCodes, decide: @escaping @Sendable (KeyEvent) -> KeyDecision) {
    self.codes = codes
    self.decide = decide
  }

  private func begin() -> Bool {
    let events: [CGEventType] = [
      .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]
    let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    let callback: CGEventTapCallBack = { _, type, event, pointer in
      guard let pointer else { return Unmanaged.passUnretained(event) }
      let listener = Unmanaged<KeyTap>.fromOpaque(pointer).takeUnretainedValue()
      return listener.handle(type, event) ? nil : Unmanaged.passUnretained(event)
    }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask, callback: callback,
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return false }
    self.tap = tap
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread { [self] in
      guard let tap = self.tap else { return }
      let runLoop = CFRunLoopGetCurrent()
      self.runLoop = runLoop
      CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
      ready.signal()
      CFRunLoopRun()
    }
    thread.name = "com.elevenideas.Atelier.keys"
    self.thread = thread
    thread.start()
    ready.wait()
    // Watched from here, so that stopping the tap also stops this.
    activation = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
    ) { [decide] notification in
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      guard app?.processIdentifier != getpid() else { return }
      _ = decide(.appSwitched)
    }
    return true
  }

  /// True to consume the event.
  private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      // macOS turns a slow tap off; ours is quick, so it is turned on again.
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return false
    case .keyDown:
      guard !isStopping, event.getIntegerValueField(.eventSourceUserData) != PostedKeys.marker
      else { return false }
      let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
      let modifiers = Chord.Modifiers(event.flags).subtracting(.function)
      let chord = Chord(modifiers, codes.name(of: code) ?? "")
      guard decide(.keyDown(chord)) == .consume else { return false }
      consumedDowns.insert(code)
      return true
    case .keyUp:
      let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
      let consumed = consumedDowns.remove(code) != nil
      if isStopping, consumedDowns.isEmpty { tearDown() }
      return consumed
    case .flagsChanged:
      _ = decide(.flagsChanged(Chord.Modifiers(event.flags)))
      return false
    default:
      guard !isStopping else { return false }
      _ = decide(.mouseDown)
      return false
    }
  }

  /// How long a stopping tap waits for the consumed keys to be released.
  private static let lingerTime: TimeInterval = 1

  func stop() {
    if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    activation = nil
    guard let runLoop else { return }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
      isStopping = true
      if consumedDowns.isEmpty {
        tearDown()
      } else {
        let timer = CFRunLoopTimerCreateWithHandler(
          nil, CFAbsoluteTimeGetCurrent() + Self.lingerTime, 0, 0, 0
        ) { [self] _ in tearDown() }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
      }
    }
    CFRunLoopWakeUp(runLoop)
  }

  /// On the tap's thread only.
  private func tearDown() {
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
      self.tap = nil
    }
    CFRunLoopStop(CFRunLoopGetCurrent())
  }
}
