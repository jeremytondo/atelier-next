import AppKit
import ApplicationServices

enum Accessibility {
  static var isGranted: Bool { AXIsProcessTrusted() }

  /// macOS shows its own prompt only the first time, so the settings pane is
  /// opened as well; the prompt call is what adds Atelier to the list there.
  static func request() {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
  }
}
