import AppKit
import Carbon.HIToolbox

if CommandLine.arguments.dropFirst().first == "--engine-fixture" {
  do {
    try runEngineFixture(arguments: Array(CommandLine.arguments.dropFirst(2)))
  } catch {
    FileHandle.standardError.write(Data("Engine fixture failed: \(error)\n".utf8))
    exit(1)
  }
  exit(0)
}

MainActor.assumeIsolated {
  let args = CommandLine.arguments
  if args.count > 2, args[1] == "--icon" {
    let directory = URL(fileURLWithPath: args[2], isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        NSColor(calibratedRed: 0.12, green: 0.29, blue: 0.67, alpha: 1).setFill()
        NSBezierPath(
          roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 205, yRadius: 205
        ).fill()
        for (i, opacity) in [(0, 0.40), (1, 0.65), (2, 1.0)] {
          let x = 235 + CGFloat(i) * 83
          let y = 310 - CGFloat(i) * 60
          NSColor.white.withAlphaComponent(opacity).setStroke()
          let rectangle = NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: 380, height: 430), xRadius: 42, yRadius: 42)
          rectangle.lineWidth = 30
          rectangle.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try! bitmap.representation(using: .png, properties: [:])!.write(
          to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
      }
    }
    exit(0)
  }
  if args.count > 3, args[1] == "--key" {
    let key = UInt16(args[2])!
    let flags = UInt64(args[3])!
    let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
    let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)!
    down.flags = CGEventFlags(rawValue: flags)
    up.flags = []
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.03)
    up.post(tap: .cghidEventTap)
    exit(0)
  }
  if args.count > 2, args[1] == "--modifiers" {
    let flags = CGEventFlags(rawValue: UInt64(args[2])!)
    for code: CGKeyCode in [55, 58] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: !flags.isEmpty)!
      event.flags = flags
      event.post(tap: .cghidEventTap)
    }
    exit(0)
  }
  if args.count > 1, args[1] == "--windows" {
    let descriptions =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0)
      as? [[String: Any]] ?? []
    let filtered = descriptions.filter {
      ($0[kCGWindowOwnerName as String] as? String) == "Atelier"
    }
    print(
      String(
        data: try! JSONSerialization.data(withJSONObject: filtered, options: .prettyPrinted),
        encoding: .utf8)!)
    exit(0)
  }
  // Disposable local fixture, never bundled in the installed app.
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let main = NSMenu()
  let appItem = NSMenuItem()
  let appMenu = NSMenu()
  appMenu.addItem(
    withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  appItem.submenu = appMenu
  main.addItem(appItem)
  let windowItem = NSMenuItem()
  let windowMenu = NSMenu(title: "Window")
  windowMenu.addItem(
    withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
  windowMenu.addItem(
    withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
  windowItem.submenu = windowMenu
  main.addItem(windowItem)
  app.mainMenu = main
  app.windowsMenu = windowMenu
  var windows: [NSWindow] = []
  for i in 1...3 {
    let window = NSWindow(
      contentRect: NSRect(
        x: CGFloat(100 + i * 40), y: CGFloat(100 + i * 40), width: 680, height: 450),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "Atelier Test \(i)"
    window.isReleasedWhenClosed = false
    let text = NSTextField(labelWithString: "Disposable Atelier test window \(i)")
    text.font = .systemFont(ofSize: 24)
    text.frame = NSRect(x: 35, y: 190, width: 600, height: 60)
    window.contentView?.addSubview(text)
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
  }
  app.activate(ignoringOtherApps: true)
  withExtendedLifetime(windows) { app.run() }
}
