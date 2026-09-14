// An explicitly requested, saved test window. Keyboard input is emitted only
// after both its native membership and exact focused window ID are confirmed.
import AppKit
import NativeBridge
import Trial

func typingFixture(directory: URL, spaceID: UInt64) throws -> [String: Any] {
  guard AXIsProcessTrusted() else { throw TrialError("Typing fixture requires Accessibility trust") }
  guard try Creation.decode(nativeCensus()).contains(where: { $0.currentSpaceID == spaceID }) else {
    throw TrialError("Expected Desktop is not active")
  }
  let start = ProcessInfo.processInfo.systemUptime
  // A nested CF run loop services sources but does not deliver AppKit's queued
  // keyboard events. This synchronous fixture must pump NSApplication too.
  func pumpInput() {
    if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
      inMode: .default, dequeue: true) { NSApplication.shared.sendEvent(event) }
  }
  let file = directory.appendingPathComponent("typing-fixture-\(UUID()).txt")
  try Data("ATE-40 saved fixture.\n".utf8).write(to: file, options: .withoutOverwriting)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  let original = NSWorkspace.shared.frontmostApplication
  let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 250),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.title = "ATE-40 saved typing fixture"
  let text = NSTextView(frame: window.contentView!.bounds)
  text.string = try String(contentsOf: file, encoding: .utf8)
  window.contentView = text
  defer { window.close(); original?.activate(options: []) }
  NSApplication.shared.activate(ignoringOtherApps: true)
  window.makeKeyAndOrderFront(nil)
  window.makeFirstResponder(text)
  text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
  let deadline = start + 1.5
  var focused = false
  repeat {
    pumpInput()
    let observation = NativeBridge.observation() as! [String: Any]
    let memberships = observation["memberships"] as? [String: [NSNumber]] ?? [:]
    focused = observation["focusedWindow"] as? Int == window.windowNumber &&
      memberships[String(window.windowNumber)]?.contains(NSNumber(value: spaceID)) == true
    if focused { break }
  } while ProcessInfo.processInfo.systemUptime < deadline
  guard focused else { throw TrialError("Saved fixture focus/membership was not confirmed; no typing sent") }
  let focusMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
  let onActiveSpace = window.isOnActiveSpace
  let phrase = "ATE40 verified typing"
  let characters = Array(phrase.utf16)
  let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
  down.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
  up.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
  down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
  let typingDeadline = ProcessInfo.processInfo.systemUptime + 1
  repeat {
    pumpInput()
    if text.string.contains(phrase) { break }
  } while ProcessInfo.processInfo.systemUptime < typingDeadline
  try text.string.write(to: file, atomically: true, encoding: .utf8)
  let listed = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
  let visible = listed.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }
  return ["typed": text.string.contains(phrase), "savedFile": file.path, "windowID": window.windowNumber,
    "focusMilliseconds": focusMilliseconds, "onActiveSpace": onActiveSpace, "visible": visible,
    "spaceID": String(spaceID), "inputToTypedMilliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
    "windowClosedOnReturn": true]
}
