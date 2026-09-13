import AppKit
import AtelierCore
import Carbon.HIToolbox

@MainActor
final class GroupOverlay {
  private let panel: NSPanel
  private var monitor: Timer?
  private(set) var active = false
  var onChord: (() -> Void)?
  var current: (() -> (WindowGroup?, WindowKey?, Bool))?
  private var modifiers: CGEventFlags = [.maskCommand, .maskAlternate]
  private var memberLabels: [Int: String] = [:]
  private var hint = ""
  func configure(_ config: AppConfiguration) {
    let flags = (try? Shortcut(config.overlayModifiers + "-a"))?.modifiers ?? 0
    modifiers = []
    for (carbon, event) in [
      (cmdKey, CGEventFlags.maskCommand), (optionKey, .maskAlternate),
      (controlKey, .maskControl), (shiftKey, .maskShift),
    ] where flags & UInt32(carbon) != 0 {
      modifiers.insert(event)
    }
    let bindings = (try? config.effectiveBindings()) ?? [:]
    memberLabels = Dictionary(
      uniqueKeysWithValues: (1...10).map { ($0, bindings["select-\($0)"]?.label ?? "—") })
    hint = [
      bindings["cycle-previous"].map { "\($0.label) previous" },
      bindings["cycle-next"].map { "\($0.label) next" },
    ].compactMap { $0 }.joined(separator: "  ·  ")
  }
  init() {
    panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.isReleasedWhenClosed = false
  }
  func start() {
    stop()
    // Read global modifier state, never intercept keyboard input. No event tap
    // or additional Input Monitoring permission is needed for this overlay.
    let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    monitor = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private func tick() {
    let flags = CGEventSource.flagsState(.combinedSessionState)
    let held =
      flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]) == modifiers
    if held != active {
      active = held
      if held { onChord?() }
      redraw()
    }
  }
  func redraw() {
    guard active, let (group, focus, missionControl) = current?(), let group,
      !group.members.isEmpty, !missionControl
    else {
      panel.orderOut(nil)
      return
    }
    let screen =
      group.key.display == "Main"
      ? NSScreen.screens.first
      : NSScreen.screens.first { screen in
        guard
          let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? UInt32,
          let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
          let string = CFUUIDCreateString(nil, uuid)
        else { return false }
        return (string as String).caseInsensitiveCompare(group.key.display) == .orderedSame
      }
    guard let screen else {
      panel.orderOut(nil)
      return
    }
    let usable = screen.visibleFrame
    let rows = max(1, Int((usable.height - 120) / 42))
    let columns = Int(ceil(Double(group.members.count) / Double(rows)))
    let width = min(CGFloat(columns) * 320, usable.width - 40)
    let height = CGFloat(min(group.members.count, rows)) * 42 + 76
    panel.setFrame(
      NSRect(x: usable.maxX - width - 20, y: usable.minY + 20, width: width, height: height),
      display: false)
    let content = (panel.contentView as? OverlayContent) ?? OverlayContent()
    content.group = group
    content.focus = focus
    content.rows = rows
    content.memberLabels = memberLabels
    content.hint = hint
    panel.contentView = content
    content.needsDisplay = true
    panel.orderFrontRegardless()
  }
  var showing: Bool { panel.isVisible }
  func stop() {
    monitor?.invalidate()
    monitor = nil
    active = false
    panel.orderOut(nil)
  }
}

private final class OverlayContent: NSView {
  var group: WindowGroup?
  var focus: WindowKey?
  var rows = 1
  var memberLabels: [Int: String] = [:]
  var hint = ""
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(calibratedWhite: 0.09, alpha: 0.97).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    guard let group else { return }
    func text(
      _ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, dim: Bool = false
    ) {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byTruncatingTail
      string.replacingOccurrences(of: "\n", with: " ").draw(
        in: NSRect(x: x, y: y, width: width, height: size + 6),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: size),
          .foregroundColor: NSColor.white.withAlphaComponent(dim ? 0.55 : 1),
          .paragraphStyle: paragraph,
        ])
    }
    text("GROUP WINDOWS", x: 18, y: 14, width: bounds.width - 36, size: 11, dim: true)
    text(
      hint, x: 18, y: bounds.height - 27, width: bounds.width - 36,
      size: 11, dim: true)
    let columns = max(1, Int(ceil(Double(group.members.count) / Double(rows))))
    let columnWidth = bounds.width / CGFloat(columns)
    let counts = Dictionary(group.members.map { ($0.app, 1) }, uniquingKeysWith: +)
    for (index, member) in group.members.enumerated() {
      let x = CGFloat(index / rows) * columnWidth
      let y = 38 + CGFloat(index % rows) * 42
      if member.key == focus {
        NSColor.systemBlue.withAlphaComponent(0.4).setFill()
        NSBezierPath(
          roundedRect: NSRect(x: x + 9, y: y - 2, width: columnWidth - 18, height: 38), xRadius: 7,
          yRadius: 7
        ).fill()
      }
      let duplicate = counts[member.app, default: 0] > 1
      text(
        memberLabels[index + 1] ?? "—", x: x + 19, y: y + 5, width: 82, size: 11, dim: index > 9)
      text(member.app, x: x + 105, y: y + (duplicate ? 0 : 5), width: columnWidth - 122, size: 14)
      if duplicate {
        text(
          member.title.isEmpty ? "Untitled window" : member.title, x: x + 105, y: y + 18,
          width: columnWidth - 122, size: 10, dim: true)
      }
    }
  }
}
