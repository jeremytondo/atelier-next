import AppKit
import AtelierCore
import SwiftUI

@main
struct AtelierApp {
  @MainActor static func main() {
    let args = CommandLine.arguments
    if args.contains("--version") {
      let info = Bundle.main.infoDictionary ?? [:]
      let version = info["AtelierBuildVersion"] as? String ?? "development"
      let build = info["CFBundleVersion"] as? String ?? "unknown"
      print("Atelier \(version) (build \(build))")
      return
    }
    if args.contains("--config-path") {
      print(ConfigurationFiles.directory().appendingPathComponent("config.toml").path)
      return
    }
    if let index = args.firstIndex(of: "--validate-config") {
      let url =
        args.indices.contains(index + 1)
        ? URL(fileURLWithPath: args[index + 1])
        : ConfigurationFiles.directory().appendingPathComponent("config.toml")
      do {
        let loaded = try ConfigurationFiles.load(url)
        print(
          "Valid configuration: \(loaded.files.count) file(s), \(loaded.configuration.quickApps.count) Quick App(s)."
        )
      } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
      }
      return
    }
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { application.run() }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var item: NSStatusItem?
  private var window: NSWindow?
  private var controller: Controller!
  private var settings: ConfigurationStore!
  private var appLock: Int32 = -1
  private var signals: [DispatchSourceSignal] = []
  private var diagnosticControl: DiagnosticControl?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let lockPath = "/tmp/com.elevenideas.Atelier.\(getuid()).lock"
    appLock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard appLock >= 0, lockf(appLock, F_TLOCK, 0) == 0 else {
      NSRunningApplication.runningApplications(
        withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
      ).first(where: { $0.processIdentifier != getpid() })?.activate()
      NSApp.terminate(nil)
      return
    }
    settings = ConfigurationStore()
    controller = Controller(settings: settings)
    for number in [SIGTERM, SIGINT] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { NSApp.terminate(nil) }
      source.resume()
      signals.append(source)
    }
    if CommandLine.arguments.contains("--diagnostic-control") {
      let control = DiagnosticControl(controller: controller)
      control.capture = { [weak self] tab in
        guard let self else { throw CocoaError(.coderInvalidValue) }
        self.showStatus()
        self.window?.contentView = NSHostingView(
          rootView: StatusView(controller: self.controller, settings: self.settings))
        self.window?.contentView?.layoutSubtreeIfNeeded()
        guard let view = self.window?.contentView,
          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { throw CocoaError(.coderInvalidValue) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
          throw CocoaError(.coderInvalidValue)
        }
        let url = self.settings.stateDirectory.appendingPathComponent(
          "diagnostic-control/status-\(tab).png")
        try png.write(to: url)
        return url.path
      }
      diagnosticControl = control
    }
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item?.button?.image = NSImage(
      systemSymbolName: "rectangle.3.group", accessibilityDescription: "Atelier")
    item?.button?.image?.isTemplate = true
    controller.changed = { [weak self] in self?.updateMenu() }
    updateMenu()
    installMainMenu()
    if !controller.accessibility || settings.loadFailed { showStatus() }
    Task {
      await controller.start()
      if !controller.running { showStatus() }
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showStatus()
    return true
  }
  private func installMainMenu() {
    let menu = NSMenu()
    let app = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Open Configuration…", action: #selector(openConfiguration), keyEquivalent: ","
    )
    .target = self
    appMenu.addItem(
      withTitle: "Reload Configuration", action: #selector(reloadConfiguration), keyEquivalent: ""
    ).target = self
    appMenu.addItem(withTitle: "Status…", action: #selector(showStatus), keyEquivalent: "").target =
      self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Atelier", action: #selector(quit), keyEquivalent: "q").target =
      self
    app.submenu = appMenu
    menu.addItem(app)
    let edit = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    for (title, action, key) in [
      ("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
      ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
    edit.submenu = editMenu
    menu.addItem(edit)
    NSApp.mainMenu = menu
  }
  private func updateMenu() {
    guard let controller else { return }
    let menu = NSMenu()
    menu.addItem(withTitle: "Atelier · \(controller.state)", action: nil, keyEquivalent: "")
    if controller.lastError != nil || controller.configurationError != nil || settings.loadFailed
      || !controller.quickErrors.isEmpty
    {
      menu.addItem(
        withTitle: "View Issue…", action: #selector(showStatus),
        keyEquivalent: ""
      ).target = self
    }
    menu.addItem(.separator())
    menu.addItem(
      withTitle: controller.running ? "Pause" : "Resume", action: #selector(toggle),
      keyEquivalent: ""
    ).target = self
    menu.addItem(
      withTitle: "Open Configuration…", action: #selector(openConfiguration), keyEquivalent: ","
    )
    .target = self
    let shortcut = (try? settings.configuration.effectiveBindings()["reload-config"])?.label
    let reloadTitle = "Reload Configuration" + (shortcut.map { "  \($0)" } ?? "")
    menu.addItem(withTitle: reloadTitle, action: #selector(reloadConfiguration), keyEquivalent: "")
      .target = self
    menu.addItem(
      withTitle: "Open Configuration Folder", action: #selector(openConfigurationFolder),
      keyEquivalent: ""
    ).target = self
    menu.addItem(
      withTitle: "Configuration Reference", action: #selector(openReference), keyEquivalent: ""
    ).target = self
    menu.addItem(withTitle: "Status…", action: #selector(showStatus), keyEquivalent: "").target =
      self
    menu.addItem(withTitle: "Export Diagnostics…", action: #selector(export), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Atelier", action: #selector(quit), keyEquivalent: "q").target =
      self
    item?.menu = menu
    item?.button?.toolTip = "Atelier — \(controller.state)"
  }
  @objc private func toggle() {
    if controller.running { controller.pause() } else { Task { await controller.start() } }
  }
  @objc private func openConfiguration() { settings.openConfiguration() }
  @objc private func openConfigurationFolder() { NSWorkspace.shared.open(settings.directory) }
  @objc private func openReference() { settings.openReference() }
  @objc private func reloadConfiguration() { Task { await controller.reloadConfiguration() } }
  @objc private func showStatus() {
    if window == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "Atelier"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: StatusView(controller: controller, settings: settings))
      window.center()
      self.window = window
    }
    settings.updateLoginStatus()
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
  @objc private func export() { controller.exportDiagnostics() }
  @objc private func quit() { NSApp.terminate(nil) }
  func applicationWillTerminate(_ notification: Notification) {
    controller?.shutdown()
    diagnosticControl?.stop()
    if appLock >= 0 { close(appLock) }
  }
}
