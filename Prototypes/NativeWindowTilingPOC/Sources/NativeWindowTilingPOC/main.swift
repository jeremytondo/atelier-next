import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import WindowManagementBridge

private enum TileCommand: String, CaseIterable {
    case left
    case right
    case fill
    case top
    case bottom
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    case center
    case untile

    var selectorName: String {
        switch self {
        case .left: "_zoomLeft:"
        case .right: "_zoomRight:"
        case .fill: "_zoomFill:"
        case .top: "_zoomTop:"
        case .bottom: "_zoomBottom:"
        case .topLeft: "_zoomTopLeft:"
        case .topRight: "_zoomTopRight:"
        case .bottomLeft: "_zoomBottomLeft:"
        case .bottomRight: "_zoomBottomRight:"
        case .center: "_zoomCenter:"
        case .untile: "_zoomUntile:"
        }
    }

    var windowManagementPosition: UInt {
        switch self {
        case .top: 1
        case .left: 2
        case .bottom: 3
        case .right: 4
        case .center: 5
        case .fill: 6
        case .untile: 7
        case .topLeft: 8
        case .topRight: 9
        case .bottomLeft: 10
        case .bottomRight: 11
        }
    }

    var systemKeyboardShortcut: (keyCode: CGKeyCode, flags: CGEventFlags)? {
        let flags: CGEventFlags = [.maskControl, .maskSecondaryFn]
        return switch self {
        case .left: (123, flags)
        case .right: (124, flags)
        case .bottom: (125, flags)
        case .top: (126, flags)
        case .fill: (3, flags) // F
        case .center: (8, flags) // C
        case .untile: (15, flags) // R (Return to Previous Size)
        case .topLeft, .topRight, .bottomLeft, .bottomRight: nil
        }
    }
}

private struct Options {
    let command: TileCommand
    let probeOnly: Bool
    let smokeTest: Bool
    let fixture: Bool
    let crossProcessSmokeTest: Bool
    let keyboardCrossProcessSmokeTest: Bool
    let standardAppKeyboardSmokeTest: Bool
    let standardAppMenuSmokeTest: Bool
    let focusedWindow: Bool
    let requestAccessibility: Bool
    let coordinatorSmokeTest: Bool

    static func parse(_ arguments: [String]) throws -> Options {
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            exit(EXIT_SUCCESS)
        }

        let probeOnly = arguments.contains("--probe")
        let smokeTest = arguments.contains("--smoke-test")
        let fixture = arguments.contains("--fixture")
        let crossProcessSmokeTest = arguments.contains("--cross-process-smoke-test")
        let keyboardCrossProcessSmokeTest = arguments.contains("--keyboard-cross-process-smoke-test")
        let standardAppKeyboardSmokeTest = arguments.contains("--standard-app-keyboard-smoke-test")
        let standardAppMenuSmokeTest = arguments.contains("--standard-app-menu-smoke-test")
        let focusedWindow = arguments.contains("--focused-window")
        let requestAccessibility = arguments.contains("--request-accessibility")
        let coordinatorSmokeTest = arguments.contains("--coordinator-smoke-test")
        let commandArgument = arguments.dropFirst().first { !$0.hasPrefix("-") }
        let command = commandArgument.flatMap(TileCommand.init(rawValue:)) ?? .left

        if let commandArgument, TileCommand(rawValue: commandArgument) == nil {
            throw POCError.invalidCommand(commandArgument)
        }
        if focusedWindow && [probeOnly, smokeTest, fixture, crossProcessSmokeTest,
                             keyboardCrossProcessSmokeTest, standardAppKeyboardSmokeTest,
                             standardAppMenuSmokeTest, coordinatorSmokeTest].contains(true) {
            throw POCError.observation("--focused-window cannot be combined with another test mode")
        }

        return Options(
            command: command,
            probeOnly: probeOnly,
            smokeTest: smokeTest,
            fixture: fixture,
            crossProcessSmokeTest: crossProcessSmokeTest,
            keyboardCrossProcessSmokeTest: keyboardCrossProcessSmokeTest,
            standardAppKeyboardSmokeTest: standardAppKeyboardSmokeTest,
            standardAppMenuSmokeTest: standardAppMenuSmokeTest,
            focusedWindow: focusedWindow,
            requestAccessibility: requestAccessibility,
            coordinatorSmokeTest: coordinatorSmokeTest
        )
    }

    static func printUsage() {
        let commands = TileCommand.allCases.map(\.rawValue).joined(separator: ", ")
        print("""
        Usage: native-window-tiling-poc [command] [--probe] [--smoke-test]

        Commands: \(commands)

          --probe       Resolve the private APIs without opening a window.
          --smoke-test  Tile the window, report its resulting bounds, then quit.
          --cross-process-smoke-test
                        Ask WindowManagement to tile a separate fixture process.
          --keyboard-cross-process-smoke-test
                        Send the system tiling shortcut directly to a fixture PID.
          --standard-app-keyboard-smoke-test
                        Compare targeted/global delivery using a disposable TextEdit.
          --standard-app-menu-smoke-test
                        Invoke a native menu action by AXIdentifier, then restore size.
          --focused-window
                        Wait five seconds, then invoke the native command on your
                        focused window. Leaves the result in place; use untile to restore.
          --request-accessibility
                        Ask macOS to show the Accessibility permission UI.
          --coordinator-smoke-test
                        Tile this process's window through NSWMWindowCoordinator.
        """)
    }
}

private enum POCError: LocalizedError {
    case invalidCommand(String)
    case frameworkLoad(String)
    case missingSymbol(String)
    case unsupportedSelector(String)
    case unsupportedKeyboardShortcut(String)
    case eventCreation
    case observation(String)

    var errorDescription: String? {
        switch self {
        case let .invalidCommand(command):
            "Unknown tiling command: \(command)"
        case let .frameworkLoad(message):
            "Could not load SkyLight.framework: \(message)"
        case let .missingSymbol(symbol):
            "SkyLight.framework does not export \(symbol) on this macOS build"
        case let .unsupportedSelector(selector):
            "NSWindow does not implement the private selector \(selector) on this macOS build"
        case let .unsupportedKeyboardShortcut(command):
            "The keyboard-event prototype does not define a system shortcut for \(command)"
        case .eventCreation:
            "CoreGraphics could not create the synthetic keyboard event"
        case let .observation(message):
            message
        }
    }
}

/// A deliberately tiny runtime bridge. Nothing is linked against SkyLight at build time.
private final class SkyLightConnection {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias GetWindowBounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32

    private static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    private let handle: UnsafeMutableRawPointer
    private let getWindowBounds: GetWindowBounds
    let connectionID: Int32

    init() throws {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw POCError.frameworkLoad(message)
        }

        guard let mainConnectionSymbol = dlsym(handle, "SLSMainConnectionID") else {
            dlclose(handle)
            throw POCError.missingSymbol("SLSMainConnectionID")
        }

        guard let getWindowBoundsSymbol = dlsym(handle, "SLSGetWindowBounds") else {
            dlclose(handle)
            throw POCError.missingSymbol("SLSGetWindowBounds")
        }

        let mainConnection = unsafeBitCast(mainConnectionSymbol, to: MainConnectionID.self)
        self.handle = handle
        self.getWindowBounds = unsafeBitCast(getWindowBoundsSymbol, to: GetWindowBounds.self)
        self.connectionID = mainConnection()
    }

    deinit {
        dlclose(handle)
    }

    func bounds(of windowNumber: Int) -> CGRect? {
        var bounds = CGRect.zero
        let result = getWindowBounds(connectionID, UInt32(windowNumber), &bounds)
        return result == 0 ? bounds : nil
    }
}

@MainActor
private enum NativeTilingAPI {
    static func supports(_ command: TileCommand) -> Bool {
        NSWindow.instancesRespond(to: NSSelectorFromString(command.selectorName))
    }

    static func tile(_ window: NSWindow, using command: TileCommand) throws {
        let selector = NSSelectorFromString(command.selectorName)
        guard window.responds(to: selector) else {
            throw POCError.unsupportedSelector(command.selectorName)
        }

        // This intentionally calls an undocumented AppKit selector at runtime.
        // AppKit routes it through Apple's WindowManagement machinery and applies
        // the system tiling animation/state to the receiving window.
        _ = window.perform(selector, with: nil)
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private let skyLight: SkyLightConnection
    private var window: NSWindow?

    init(options: Options, skyLight: SkyLightConnection) {
        self.options = options
        self.skyLight = skyLight
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = makeWindow()
        self.window = window

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("Opened test window #\(window.windowNumber)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.invokeTilingCommand()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ATE-13 · Native Window Tiling POC"
        window.minSize = NSSize(width: 320, height: 240)

        let label = NSTextField(labelWithString: "macOS will invoke \(options.command.selectorName) on this window.")
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: "Close the window to exit.")
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, detail])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
        ])
        window.contentView = contentView
        return window
    }

    private func invokeTilingCommand() {
        guard let window else { return }
        print("SkyLight bounds before: \(format(skyLight.bounds(of: window.windowNumber)))")

        do {
            if options.coordinatorSmokeTest {
                var diagnostic: NSString?
                guard ATRequestNativeTilingForLocalWindow(
                    window,
                    options.command.windowManagementPosition,
                    &diagnostic
                ) else {
                    throw POCError.frameworkLoad(diagnostic as String? ?? "coordinator submission failed")
                }
                print("WindowManagement coordinator: \(diagnostic ?? "submitted")")
            } else {
                try NativeTilingAPI.tile(window, using: options.command)
                print("Invoked \(options.command.selectorName)")
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let window = self.window else { return }
            print("SkyLight bounds after:  \(self.format(self.skyLight.bounds(of: window.windowNumber)))")
            if self.options.smokeTest {
                NSApp.terminate(nil)
            }
        }
    }

    private func format(_ bounds: CGRect?) -> String {
        guard let bounds else { return "unavailable" }
        return String(
            format: "x=%.0f y=%.0f width=%.0f height=%.0f",
            bounds.origin.x,
            bounds.origin.y,
            bounds.size.width,
            bounds.size.height
        )
    }
}

@MainActor
private final class FixtureApplicationDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ATE-13 · Cross-Process Fixture"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        let selector = NSSelectorFromString("_persistentIdentifierForWindowManagement")
        guard
            let identifier = window.perform(selector)?.takeUnretainedValue() as? String
        else {
            fputs("error: fixture could not obtain its WindowManagement identifier\n", stderr)
            NSApp.terminate(nil)
            return
        }

        print("FIXTURE_WINDOW=\(window.windowNumber)\t\(identifier)")
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
private func probe(skyLight: SkyLightConnection) {
    print("SkyLight connection ID: \(skyLight.connectionID)")
    for command in TileCommand.allCases {
        let status = NativeTilingAPI.supports(command) ? "available" : "missing"
        print("\(command.rawValue): \(command.selectorName) [\(status)]")
    }
}

private func readLine(from handle: FileHandle) -> String? {
    var data = Data()
    while true {
        let byte = handle.readData(ofLength: 1)
        guard !byte.isEmpty else { break }
        if byte.first == 0x0A { break }
        data.append(byte)
    }
    return data.isEmpty ? nil : String(data: data, encoding: .utf8)
}

@MainActor
private func runFixture() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = FixtureApplicationDelegate()
    application.delegate = delegate
    application.run()
    withExtendedLifetime(delegate) {}
}

@MainActor
private func runCrossProcessSmokeTest(command: TileCommand, skyLight: SkyLightConnection) throws {
    let fixture = Process()
    let output = Pipe()
    let errors = Pipe()
    fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    fixture.arguments = ["--fixture"]
    fixture.standardOutput = output
    fixture.standardError = errors
    try fixture.run()

    defer {
        if fixture.isRunning {
            fixture.terminate()
            fixture.waitUntilExit()
        }
    }

    var fixtureDescription: String?
    while let line = readLine(from: output.fileHandleForReading) {
        if line.hasPrefix("FIXTURE_WINDOW=") {
            fixtureDescription = line
            break
        }
    }

    guard let fixtureDescription else {
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8) ?? "unknown fixture error"
        throw POCError.frameworkLoad("fixture did not publish a window: \(errorText)")
    }

    let fields = fixtureDescription
        .dropFirst("FIXTURE_WINDOW=".count)
        .split(separator: "\t", maxSplits: 1)
    guard
        fields.count == 2,
        let windowNumber = Int(fields[0])
    else {
        throw POCError.frameworkLoad("invalid fixture response: \(fixtureDescription)")
    }
    let identifier = String(fields[1])

    print("Fixture window #\(windowNumber), WindowManagement ID \(identifier)")
    let registrationDeadline = Date().addingTimeInterval(2)
    var before = skyLight.bounds(of: windowNumber)
    while (before == nil || before == .zero) && Date() < registrationDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        before = skyLight.bounds(of: windowNumber)
    }
    print("SkyLight bounds before: \(formatBounds(before))")

    var diagnostic: NSString?
    guard ATRequestNativeTiling(identifier, command.windowManagementPosition, &diagnostic) else {
        throw POCError.frameworkLoad(diagnostic as String? ?? "transaction submission failed")
    }
    print("WindowManagement transaction: \(diagnostic ?? "submitted")")

    let deadline = Date().addingTimeInterval(4)
    var after = before
    repeat {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        after = skyLight.bounds(of: windowNumber)
    } while after == before && Date() < deadline

    print("SkyLight bounds after:  \(formatBounds(after))")
    guard let before, let after, before != .zero, after != .zero else {
        throw POCError.observation("RESULT: inconclusive — valid before/after bounds are required")
    }
    if after == before {
        print("RESULT: rejected or ignored — the foreign window did not move")
    } else {
        print("RESULT: bounds changed — native tiling still requires independent verification")
    }
}

private func formatBounds(_ bounds: CGRect?) -> String {
    guard let bounds else { return "unavailable" }
    return String(
        format: "x=%.0f y=%.0f width=%.0f height=%.0f",
        bounds.origin.x,
        bounds.origin.y,
        bounds.size.width,
        bounds.size.height
    )
}

private enum KeyboardEventDestination {
    case process(pid_t)
    case global
}

private func postSystemTilingShortcut(
    _ command: TileCommand,
    to destination: KeyboardEventDestination
) throws {
    guard let shortcut = command.systemKeyboardShortcut else {
        throw POCError.unsupportedKeyboardShortcut(command.rawValue)
    }
    guard
        let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: shortcut.keyCode,
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: shortcut.keyCode,
            keyDown: false
        )
    else {
        throw POCError.eventCreation
    }
    keyDown.flags = shortcut.flags
    keyUp.flags = shortcut.flags

    func post(_ event: CGEvent) {
        switch destination {
        case let .process(processID):
            event.postToPid(processID)
        case .global:
            event.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.08)
    }
    post(keyDown)
    post(keyUp)
}

private func postMinimizeShortcut(to destination: KeyboardEventDestination) throws {
    let mKey: CGKeyCode = 46
    let commandFlag: CGEventFlags = [.maskCommand]
    guard
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: mKey, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: mKey, keyDown: false)
    else {
        throw POCError.eventCreation
    }
    keyDown.flags = commandFlag
    keyUp.flags = commandFlag
    switch destination {
    case let .process(processID): keyDown.postToPid(processID)
    case .global: keyDown.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.08)
    switch destination {
    case let .process(processID): keyUp.postToPid(processID)
    case .global: keyUp.post(tap: .cghidEventTap)
    }
}

private func accessibilityIsTrusted(requestIfNeeded: Bool) -> Bool {
    guard requestIfNeeded else { return AXIsProcessTrusted() }
    let options = [
        "AXTrustedCheckOptionPrompt": true,
    ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

private func copyAXAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func printTilingMenuDiagnostics(processID: pid_t) {
    let application = AXUIElementCreateApplication(processID)
    guard let menuBarValue = copyAXAttribute(application, "AXMenuBar") else {
        print("AX menu diagnostic: target menu bar unavailable")
        return
    }
    let menuBar = unsafeDowncast(menuBarValue, to: AXUIElement.self)
    var queue: [(AXUIElement, Int)] = [(menuBar, 0)]
    var matchingItems: [String] = []

    while let (element, depth) = queue.first {
        queue.removeFirst()
        guard depth <= 5 else { continue }

        if let title = copyAXAttribute(element, "AXTitle") as? String,
           ["Move & Resize", "Left", "Right", "Top", "Bottom", "Fill", "Center"].contains(title) {
            let commandCharacter = copyAXAttribute(element, "AXMenuItemCmdChar") as? String ?? "none"
            let virtualKey = (copyAXAttribute(element, "AXMenuItemCmdVirtualKey") as? NSNumber)?.stringValue ?? "none"
            let modifiers = (copyAXAttribute(element, "AXMenuItemCmdModifiers") as? NSNumber)?.stringValue ?? "none"
            matchingItems.append(
                "\(title){char=\(commandCharacter), virtualKey=\(virtualKey), modifiers=\(modifiers)}"
            )
        }

        guard let children = copyAXAttribute(element, "AXChildren") as? [AXUIElement] else {
            continue
        }
        queue.append(contentsOf: children.map { ($0, depth + 1) })
    }

    if matchingItems.isEmpty {
        print("AX menu diagnostic: no tiling menu items found")
    } else {
        print("AX menu diagnostic: \(matchingItems.joined(separator: "; "))")
    }
}

private func firstWindowIsMinimized(processID: pid_t) -> Bool? {
    let application = AXUIElementCreateApplication(processID)
    guard
        let windows = copyAXAttribute(application, "AXWindows") as? [AXUIElement],
        let window = windows.first
    else {
        return nil
    }
    return copyAXAttribute(window, "AXMinimized") as? Bool
}

// Research probe: discover semantic menu identifiers without opening menus or
// matching localized titles. These AppKit identifiers are not a stable contract.
private func nativeMenuItem(processID: pid_t, identifier: String) -> AXUIElement? {
    let app = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(app, 2)
    guard let value = copyAXAttribute(app, "AXMenuBar") else { return nil }
    var queue: [(AXUIElement, Int)] = [(unsafeDowncast(value, to: AXUIElement.self), 0)]
    var index = 0
    while index < queue.count && index < 2_000 {
        let (element, depth) = queue[index]
        index += 1
        if copyAXAttribute(element, "AXIdentifier") as? String == identifier {
            return element
        }
        if depth < 7, let children = copyAXAttribute(element, "AXChildren") as? [AXUIElement] {
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
    }
    return nil
}

@MainActor
private func dispatchNativeMenuCommand(
    _ command: TileCommand,
    processID: pid_t,
    window: AXUIElement
) throws {
    let started = ProcessInfo.processInfo.systemUptime
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
        throw POCError.observation("Target lost foreground focus; no menu action sent")
    }
    guard let item = nativeMenuItem(processID: processID, identifier: command.selectorName) else {
        throw POCError.observation("This app does not expose the native \(command.rawValue) menu command")
    }
    var actions: CFArray?
    let actionError = AXUIElementCopyActionNames(item, &actions)
    guard copyAXAttribute(item, "AXEnabled") as? Bool == true,
          actionError == .success, (actions as? [String])?.contains(kAXPressAction) == true else {
        throw POCError.observation("Native \(command.rawValue) is unavailable for this window")
    }
    let application = AXUIElementCreateApplication(processID)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
          let focused = copyAXAttribute(application, "AXFocusedWindow"),
          CFEqual(focused, window) else {
        throw POCError.observation("Focused window changed during discovery; no menu action sent")
    }
    let dispatchStarted = ProcessInfo.processInfo.systemUptime
    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
    let ended = ProcessInfo.processInfo.systemUptime
    print("Native identifier: \(command.selectorName); AXPress result: \(result.rawValue)")
    print(String(format: "Discovery + dispatch: %.1f ms; dispatch alone: %.1f ms (excludes animation)",
                 (ended - started) * 1000, (ended - dispatchStarted) * 1000))
    guard result == .success else {
        throw POCError.observation("Native menu action failed with Accessibility error \(result.rawValue)")
    }
}

@MainActor
private func runFocusedWindowCommand(command: TileCommand, requestAccessibility: Bool) throws {
    guard accessibilityIsTrusted(requestIfNeeded: requestAccessibility) else {
        throw POCError.observation("Accessibility permission is missing. Enable the terminal app running this command (Ghostty if launched there), then rerun.")
    }
    print("Switch to the window you want to \(command.rawValue). Control-C cancels.")
    for seconds in stride(from: 5, through: 1, by: -1) {
        print("\(seconds)…")
        fflush(stdout)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
    guard let app = NSWorkspace.shared.frontmostApplication else {
        throw POCError.observation("No foreground application was found")
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    guard let value = copyAXAttribute(application, "AXFocusedWindow"),
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        throw POCError.observation("The foreground app has no accessible focused window")
    }
    let window = unsafeDowncast(value, to: AXUIElement.self)
    print("Target: \(app.localizedName ?? "application") (PID \(app.processIdentifier))")
    try dispatchNativeMenuCommand(command, processID: app.processIdentifier, window: window)
    print("Native command dispatched. The window stays in place; run untile to request its previous size.")
}

@MainActor
private func compareNativeMenuDelivery(
    command: TileCommand,
    skyLight: SkyLightConnection,
    processID: pid_t,
    windowNumber: Int
) throws {
    guard command != .untile else {
        throw POCError.invalidCommand("Use a placement; this probe runs untile afterward")
    }
    guard AXIsProcessTrusted() else {
        throw POCError.observation("Accessibility is not authorized; menu test is blocked")
    }
    let pointerBefore = CGEvent(source: nil)?.location
    let application = AXUIElementCreateApplication(processID)
    guard let windows = copyAXAttribute(application, "AXWindows") as? [AXUIElement],
          windows.count == 1,
          let before = skyLight.bounds(of: windowNumber), before != .zero else {
        throw POCError.observation("Expected exactly one fixture window with valid bounds")
    }
    print("MENU TEST target PID=\(processID) window=\(windowNumber) time=\(ISO8601DateFormatter().string(from: Date()))")
    print("Accessibility trusted: true; pointer before: \(String(describing: pointerBefore))")
    print("Bounds before: \(formatBounds(before))")

    func invoke(_ action: TileCommand) throws -> CGRect {
        let started = Date()
        try dispatchNativeMenuCommand(action, processID: processID, window: windows[0])
        // Wait through the animation and require several matching valid samples.
        let deadline = Date().addingTimeInterval(4)
        var last: CGRect?
        var stableSamples = 0
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            guard let current = skyLight.bounds(of: windowNumber), current != .zero else {
                throw POCError.observation("Window disappeared while observing menu action")
            }
            stableSamples = current == last ? stableSamples + 1 : 0
            last = current
            if Date().timeIntervalSince(started) >= 1.2, stableSamples >= 4 {
                print("Bounds after \(action.rawValue): \(formatBounds(current))")
                return current
            }
        }
        throw POCError.observation("Window bounds did not settle within four seconds")
    }

    let after = try invoke(command)
    let restored = try invoke(.untile)
    let pointerAfter = CGEvent(source: nil)?.location
    let restorationDelta = [
        restored.minX - before.minX,
        restored.minY - before.minY,
        restored.width - before.width,
        restored.height - before.height,
    ]
    // Native untile on the tested TextEdit fixture can return a frame differing
    // by one point. Preserve exact equality and deltas rather than concealing it.
    // This tolerance describes geometry only; native state needs separate logs.
    let restoredWithinOnePoint = restorationDelta.allSatisfy { abs($0) <= 1 }
    print("MENU OBSERVATION changed=\(after != before) restoredOriginalBounds=\(restored == before) restoredWithinOnePoint=\(restoredWithinOnePoint) pointerUnchanged=\(pointerBefore != nil && pointerBefore == pointerAfter)")
    print("RESTORE DELTA points [x,y,width,height]=\(restorationDelta)")
    guard after != before, restoredWithinOnePoint else {
        throw POCError.observation("Menu action did not change and restore the fixture bounds within one point")
    }
    print("Menu dispatch changed geometry and restored it within one point; corroborate native state with WindowManager logs. This is not an animation-quality or multi-window certification.")
}

@MainActor
private func compareKeyboardEventDelivery(
    command: TileCommand,
    skyLight: SkyLightConnection,
    requestAccessibility: Bool,
    targetDescription: String,
    processID: pid_t,
    windowNumber: Int,
    runMinimizeControl: Bool = false
) throws {
    let registrationDeadline = Date().addingTimeInterval(2)
    var before = skyLight.bounds(of: windowNumber)
    while (before == nil || before == .zero) && Date() < registrationDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        before = skyLight.bounds(of: windowNumber)
    }

    let accessibilityTrusted = accessibilityIsTrusted(requestIfNeeded: requestAccessibility)
    let eventPostingAuthorized = requestAccessibility
        ? CGRequestPostEventAccess()
        : CGPreflightPostEventAccess()
    print("\(targetDescription) window #\(windowNumber), target PID \(processID)")
    print("Accessibility trusted: \(accessibilityTrusted)")
    print("Event posting authorized: \(eventPostingAuthorized)")
    print("Secure Event Input enabled: \(IsSecureEventInputEnabled())")
    if requestAccessibility && !accessibilityTrusted {
        print("Accessibility was requested; approve it in Privacy & Security, then rerun the test.")
    }
    if requestAccessibility && !eventPostingAuthorized {
        print("Event-posting access was requested; approve it, then rerun the test.")
    }
    if accessibilityTrusted {
        printTilingMenuDiagnostics(processID: processID)
    }
    print("SkyLight bounds before: \(formatBounds(before))")

    try postSystemTilingShortcut(command, to: .process(processID))
    print("Posted Fn-Control shortcut directly to PID \(processID)")

    let deadline = Date().addingTimeInterval(4)
    var after = before
    repeat {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        after = skyLight.bounds(of: windowNumber)
    } while after == before && Date() < deadline

    print("SkyLight bounds after targeted event: \(formatBounds(after))")
    guard let before, let after, before != .zero, after != .zero else {
        throw POCError.observation("RESULT: inconclusive — valid before/after bounds are required")
    }
    if after != before {
        print("RESULT: bounds changed — native tiling still requires independent verification")
        return
    }

    guard accessibilityTrusted && eventPostingAuthorized else {
        print("RESULT: blocked — grant Accessibility/event-posting permission and rerun")
        return
    }

    print("TARGETED RESULT: ignored — Accessibility is trusted, but the target did not handle the shortcut")
    let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    print("Frontmost PID before guarded global event: \(frontmostProcessID.map(String.init) ?? "unavailable")")
    guard frontmostProcessID == processID else {
        print("GLOBAL RESULT: skipped — fixture was not frontmost")
        return
    }

    try postSystemTilingShortcut(command, to: .global)
    print("Posted the same shortcut through the global HID event tap")

    let globalDeadline = Date().addingTimeInterval(4)
    var globallyPostedBounds: CGRect? = after
    repeat {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        globallyPostedBounds = skyLight.bounds(of: windowNumber)
    } while globallyPostedBounds == after && Date() < globalDeadline

    print("SkyLight bounds after global event:   \(formatBounds(globallyPostedBounds))")
    guard let globallyPostedBounds, globallyPostedBounds != .zero else {
        throw POCError.observation("GLOBAL RESULT: inconclusive — target bounds are unavailable")
    }
    if globallyPostedBounds == after {
        print("GLOBAL RESULT: ignored — the system shortcut handler did not tile the target")
    } else {
        print("GLOBAL RESULT: bounds changed — native tiling still requires independent verification")
        return
    }

    guard runMinimizeControl else { return }
    try postMinimizeShortcut(to: .process(processID))
    let minimizeDeadline = Date().addingTimeInterval(2)
    var minimized = firstWindowIsMinimized(processID: processID)
    while minimized != true && Date() < minimizeDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        minimized = firstWindowIsMinimized(processID: processID)
    }
    print("INPUT CONTROL AXMinimized: \(minimized.map(String.init) ?? "unavailable")")
    if minimized == true {
        print("INPUT CONTROL: accepted — PID-targeted Command-M minimized the target")
    } else {
        try postMinimizeShortcut(to: .global)
        let globalMinimizeDeadline = Date().addingTimeInterval(2)
        while minimized != true && Date() < globalMinimizeDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            minimized = firstWindowIsMinimized(processID: processID)
        }
        print("INPUT CONTROL after global Command-M: \(minimized.map(String.init) ?? "unavailable")")
        if minimized == true {
            print("INPUT CONTROL: accepted — global Command-M minimized the target")
        } else {
            print("INPUT CONTROL: ignored — synthetic input did not reach the target")
        }
    }
}

@MainActor
private func runKeyboardCrossProcessSmokeTest(
    command: TileCommand,
    skyLight: SkyLightConnection,
    requestAccessibility: Bool
) throws {
    let fixture = Process()
    let output = Pipe()
    let errors = Pipe()
    fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    fixture.arguments = ["--fixture"]
    fixture.standardOutput = output
    fixture.standardError = errors
    try fixture.run()

    defer {
        if fixture.isRunning {
            fixture.terminate()
            fixture.waitUntilExit()
        }
    }

    var fixtureDescription: String?
    while let line = readLine(from: output.fileHandleForReading) {
        if line.hasPrefix("FIXTURE_WINDOW=") {
            fixtureDescription = line
            break
        }
    }

    guard let fixtureDescription else {
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8) ?? "unknown fixture error"
        throw POCError.frameworkLoad("fixture did not publish a window: \(errorText)")
    }

    let fields = fixtureDescription
        .dropFirst("FIXTURE_WINDOW=".count)
        .split(separator: "\t", maxSplits: 1)
    guard let windowNumberField = fields.first, let windowNumber = Int(windowNumberField) else {
        throw POCError.frameworkLoad("invalid fixture response: \(fixtureDescription)")
    }

    try compareKeyboardEventDelivery(
        command: command,
        skyLight: skyLight,
        requestAccessibility: requestAccessibility,
        targetDescription: "Bare fixture",
        processID: fixture.processIdentifier,
        windowNumber: windowNumber
    )
}

private func largestOnscreenWindowNumber(ownedBy processID: pid_t) -> Int? {
    guard let windowDescriptions = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return nil
    }

    return windowDescriptions.compactMap { description -> (number: Int, area: CGFloat)? in
        guard
            (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
            (description[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let number = (description[kCGWindowNumber as String] as? NSNumber)?.intValue,
            let boundsDictionary = description[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
            bounds.width >= 200,
            bounds.height >= 200
        else {
            return nil
        }
        return (number, bounds.width * bounds.height)
    }
    .max { $0.area < $1.area }?
    .number
}

@MainActor
private func runStandardAppKeyboardSmokeTest(
    command: TileCommand,
    skyLight: SkyLightConnection,
    requestAccessibility: Bool,
    useMenu: Bool = false
) throws {
    if useMenu && !accessibilityIsTrusted(requestIfNeeded: requestAccessibility) {
        throw POCError.observation("Accessibility is not authorized; menu test is blocked before launch")
    }
    let applicationPath = "/System/Applications/TextEdit.app"
    let bundleIdentifier = "com.apple.TextEdit"
    guard FileManager.default.fileExists(atPath: applicationPath) else {
        throw POCError.frameworkLoad("TextEdit is unavailable at \(applicationPath)")
    }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
        throw POCError.frameworkLoad("TextEdit is already running; quit it before this disposable test")
    }

    let documentURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ATE-13-TextEdit-Fixture-\(UUID().uuidString).txt")
    try "ATE-13 native tiling keyboard-event fixture\n".write(
        to: documentURL,
        atomically: true,
        encoding: .utf8
    )
    defer { try? FileManager.default.removeItem(at: documentURL) }

    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launcher.arguments = ["-na", applicationPath, documentURL.path]
    launcher.standardOutput = FileHandle.nullDevice
    launcher.standardError = FileHandle.nullDevice
    try launcher.run()
    launcher.waitUntilExit()

    let applicationDeadline = Date().addingTimeInterval(6)
    var application: NSRunningApplication?
    repeat {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first
    } while application == nil && Date() < applicationDeadline

    guard let application else {
        throw POCError.frameworkLoad("LaunchServices did not start TextEdit")
    }

    defer { application.terminate() }

    let processID = application.processIdentifier
    let launchDeadline = Date().addingTimeInterval(6)
    var windowNumber: Int?
    repeat {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        windowNumber = largestOnscreenWindowNumber(ownedBy: processID)
    } while windowNumber == nil && Date() < launchDeadline

    guard let windowNumber else {
        throw POCError.frameworkLoad("TextEdit did not publish a normal on-screen window")
    }

    _ = NSRunningApplication(processIdentifier: processID)?.activate(options: [.activateAllWindows])
    let activationDeadline = Date().addingTimeInterval(2)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != processID,
          Date() < activationDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    if useMenu {
        try compareNativeMenuDelivery(
            command: command,
            skyLight: skyLight,
            processID: processID,
            windowNumber: windowNumber
        )
        return
    }

    try compareKeyboardEventDelivery(
        command: command,
        skyLight: skyLight,
        requestAccessibility: requestAccessibility,
        targetDescription: "TextEdit",
        processID: processID,
        windowNumber: windowNumber,
        runMinimizeControl: true
    )
}

@MainActor
private func run() throws {
    let options = try Options.parse(CommandLine.arguments)

    if options.focusedWindow {
        try runFocusedWindowCommand(command: options.command, requestAccessibility: options.requestAccessibility)
        return
    }

    if options.fixture {
        runFixture()
        return
    }

    let skyLight = try SkyLightConnection()
    probe(skyLight: skyLight)

    guard !options.probeOnly else { return }

    if options.crossProcessSmokeTest {
        try runCrossProcessSmokeTest(command: options.command, skyLight: skyLight)
        return
    }

    if options.keyboardCrossProcessSmokeTest {
        try runKeyboardCrossProcessSmokeTest(
            command: options.command,
            skyLight: skyLight,
            requestAccessibility: options.requestAccessibility
        )
        return
    }

    if options.standardAppKeyboardSmokeTest || options.standardAppMenuSmokeTest {
        try runStandardAppKeyboardSmokeTest(
            command: options.command,
            skyLight: skyLight,
            requestAccessibility: options.requestAccessibility,
            useMenu: options.standardAppMenuSmokeTest
        )
        return
    }

    guard NativeTilingAPI.supports(options.command) else {
        throw POCError.unsupportedSelector(options.command.selectorName)
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = ApplicationDelegate(options: options, skyLight: skyLight)
    application.delegate = delegate
    application.run()
    withExtendedLifetime(delegate) {}
}

do {
    try run()
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    Options.printUsage()
    exit(EXIT_FAILURE)
}
