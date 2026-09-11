import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import NativeMenuDispatch

private enum PrototypeError: LocalizedError {
    case accessibilityPermission
    case alreadyRunning
    case applicationNotFound(String)
    case argument(String)
    case hotKey(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermission:
            "Accessibility permission is required. Enable the terminal running this prototype in System Settings > Privacy & Security > Accessibility."
        case .alreadyRunning:
            "Another Scratchpad prototype is already running for this user"
        case let .applicationNotFound(value):
            "Could not find an application named or identified by '\(value)'"
        case let .argument(message), let .hotKey(message):
            message
        }
    }
}

private enum Placement: String, CaseIterable {
    case left
    case right
    case top
    case bottom
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    case fill
    case center

    var menuIdentifier: String {
        switch self {
        case .left: "_zoomLeft:"
        case .right: "_zoomRight:"
        case .top: "_zoomTop:"
        case .bottom: "_zoomBottom:"
        case .topLeft: "_zoomTopLeft:"
        case .topRight: "_zoomTopRight:"
        case .bottomLeft: "_zoomBottomLeft:"
        case .bottomRight: "_zoomBottomRight:"
        case .fill: "_zoomFill:"
        case .center: "_zoomCenter:"
        }
    }
}

private struct Shortcut {
    let keyCode: UInt32
    let modifiers: UInt32
    let description: String

    static func parse(_ input: String) throws -> Shortcut {
        let parts = input.lowercased().split(separator: "-").map(String.init)
        guard let lastPart = parts.last, !lastPart.isEmpty else {
            throw PrototypeError.argument("Shortcut must end with a key, for example ctrl-option-command-s")
        }
        let twoPartKey = parts.suffix(2).joined(separator: "-")
        let keyName = keyCodes[twoPartKey] == nil ? lastPart : twoPartKey
        let keyPartCount = keyName == twoPartKey ? 2 : 1

        var modifiers: UInt32 = 0
        var names: [String] = []
        for modifier in parts.dropLast(keyPartCount) {
            switch modifier {
            case "cmd", "command":
                guard modifiers & UInt32(cmdKey) == 0 else { throw duplicateModifier(modifier) }
                modifiers |= UInt32(cmdKey)
                names.append("Command")
            case "opt", "option", "alt":
                guard modifiers & UInt32(optionKey) == 0 else { throw duplicateModifier(modifier) }
                modifiers |= UInt32(optionKey)
                names.append("Option")
            case "ctrl", "control":
                guard modifiers & UInt32(controlKey) == 0 else { throw duplicateModifier(modifier) }
                modifiers |= UInt32(controlKey)
                names.append("Control")
            case "shift":
                guard modifiers & UInt32(shiftKey) == 0 else { throw duplicateModifier(modifier) }
                modifiers |= UInt32(shiftKey)
                names.append("Shift")
            default:
                throw PrototypeError.argument("Unknown shortcut modifier '\(modifier)'")
            }
        }
        guard modifiers != 0 else {
            throw PrototypeError.argument("Shortcut must include at least one modifier")
        }
        guard let keyCode = keyCodes[keyName] else {
            throw PrototypeError.argument("Unsupported shortcut key '\(keyName)'")
        }
        names.append(keyName == "space" ? "Space" : keyName.uppercased())
        return Shortcut(keyCode: keyCode, modifiers: modifiers, description: names.joined(separator: "-"))
    }

    private static func duplicateModifier(_ name: String) -> PrototypeError {
        .argument("Shortcut repeats modifier '\(name)'")
    }

    private static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9), "space": UInt32(kVK_Space),
        "return": UInt32(kVK_Return), "tab": UInt32(kVK_Tab),
        "grave": UInt32(kVK_ANSI_Grave), "minus": UInt32(kVK_ANSI_Minus),
        "equal": UInt32(kVK_ANSI_Equal), "comma": UInt32(kVK_ANSI_Comma),
        "period": UInt32(kVK_ANSI_Period), "slash": UInt32(kVK_ANSI_Slash),
        "semicolon": UInt32(kVK_ANSI_Semicolon), "quote": UInt32(kVK_ANSI_Quote),
        "left-bracket": UInt32(kVK_ANSI_LeftBracket),
        "right-bracket": UInt32(kVK_ANSI_RightBracket),
        "backslash": UInt32(kVK_ANSI_Backslash),
    ]
}

private struct TargetApplication {
    let url: URL
    let bundleIdentifier: String
    let name: String

    @MainActor
    static func resolve(_ value: String) throws -> TargetApplication {
        let url: URL?
        if value.contains("/") || value.hasSuffix(".app") {
            url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        } else if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) {
            url = bundleURL
        } else {
            url = applicationURL(named: value)
        }
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else {
            throw PrototypeError.applicationNotFound(value)
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return TargetApplication(url: url, bundleIdentifier: bundleIdentifier, name: name)
    }

    private static func applicationURL(named value: String) -> URL? {
        let requestedName = value.hasSuffix(".app") ? value : "\(value).app"
        let roots = FileManager.default.urls(
            for: .applicationDirectory,
            in: [.userDomainMask, .localDomainMask, .systemDomainMask]
        )
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let candidate as URL in enumerator
                where candidate.lastPathComponent.caseInsensitiveCompare(requestedName) == .orderedSame {
                return candidate
            }
        }
        return nil
    }
}

private struct Options {
    let target: TargetApplication
    let placement: Placement
    let shortcut: Shortcut
    let requestAccessibility: Bool
    let probe: Bool
    let automaticallyAssignAllDesktops: Bool

    @MainActor
    static func parse(_ arguments: [String]) throws -> Options {
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            exit(EXIT_SUCCESS)
        }

        var appValue: String?
        var placement = Placement.fill
        var shortcut = try Shortcut.parse("ctrl-option-command-s")
        var requestAccessibility = false
        var probe = false
        var automaticallyAssignAllDesktops = true
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--app":
                index += 1
                guard index < arguments.count else { throw PrototypeError.argument("--app needs a value") }
                appValue = arguments[index]
            case "--placement":
                index += 1
                guard index < arguments.count, let value = Placement(rawValue: arguments[index]) else {
                    throw PrototypeError.argument("--placement must be one of: \(Placement.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                placement = value
            case "--shortcut":
                index += 1
                guard index < arguments.count else { throw PrototypeError.argument("--shortcut needs a value") }
                shortcut = try Shortcut.parse(arguments[index])
            case "--request-accessibility":
                requestAccessibility = true
            case "--probe":
                probe = true
            case "--manual-space-assignment":
                automaticallyAssignAllDesktops = false
            case "--":
                break
            default:
                throw PrototypeError.argument("Unknown argument '\(argument)'. Use --help for usage.")
            }
            index += 1
        }
        guard let appValue else {
            throw PrototypeError.argument("--app is required. Use an app name, bundle identifier, or .app path.")
        }
        return Options(
            target: try TargetApplication.resolve(appValue),
            placement: placement,
            shortcut: shortcut,
            requestAccessibility: requestAccessibility,
            probe: probe,
            automaticallyAssignAllDesktops: automaticallyAssignAllDesktops
        )
    }

    private static func printUsage() {
        print("""
        Usage: scratchpad-prototype --app <name|bundle-id|path> [options]

          --placement <name>       left, right, top, bottom, top-left, top-right,
                                   bottom-left, bottom-right, fill, or center
                                   (default: fill)
          --shortcut <keys>        Modifier names followed by one key
                                   (default: ctrl-option-command-s)
          --request-accessibility  Ask macOS to show the Accessibility prompt
          --probe                  Validate configuration without launching the app
          --manual-space-assignment
                                   Do not automatically assign the app to All Desktops

        Examples:
          scratchpad-prototype --app Calculator --placement right
          scratchpad-prototype --app com.apple.Terminal --placement top-left --shortcut ctrl-option-t

        All Desktops assignment is automatic unless explicitly disabled.
        State is intentionally session-only. Control-C exits.
        """)
    }
}

private final class SingletonProcessLock {
    private let descriptor: Int32

    init() throws {
        let path = "/tmp/com.elevenideas.atelier.scratchpad.\(getuid()).lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw PrototypeError.hotKey("Could not open the Scratchpad process lock")
        }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            close(descriptor)
            throw PrototypeError.alreadyRunning
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        close(descriptor)
    }
}

private func accessibilityIsTrusted(requestIfNeeded: Bool) -> Bool {
    guard requestIfNeeded else { return AXIsProcessTrusted() }
    return AXIsProcessTrustedWithOptions([
        "AXTrustedCheckOptionPrompt": true,
    ] as CFDictionary)
}

private func copyAXAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func boolAXAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
    copyAXAttribute(element, attribute) as? Bool ?? false
}

private enum SpaceAssignmentOutcome {
    case alreadyAssigned
    case privateAPI
    case privateAPIUnverified
    case dockMenu

    var message: String {
        switch self {
        case .alreadyAssigned:
            "All Desktops already active"
        case .privateAPI:
            "All Desktops assigned through the live WindowServer session"
        case .privateAPIUnverified:
            "WindowServer accepted All Desktops; only one ordinary Desktop is available, so membership cannot be cross-checked"
        case .dockMenu:
            "All Desktops assigned through the native Dock menu"
        }
    }
}

private enum SpaceAssignmentError: LocalizedError {
    case privateAPIUnavailable
    case privateAPIFailed(Int32)
    case dockUnavailable(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .privateAPIUnavailable:
            "the private process-assignment function is unavailable"
        case let .privateAPIFailed(code):
            "the private process-assignment function returned \(code)"
        case let .dockUnavailable(message):
            "Dock automation failed: \(message)"
        case .verificationFailed:
            "macOS did not report the window on multiple Desktops after either assignment route"
        }
    }
}

/// Applies session-level process assignment through SkyLight first, then uses
/// the user's native Dock menu as a persistent fallback. Every private symbol is
/// resolved at runtime, and a multi-Space membership read verifies the result.
@MainActor
private final class SpaceAssignmentCoordinator {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias AssignToAllSpaces = @convention(c) (Int32, pid_t) -> Int32
    private typealias CopySpacesForWindows = @convention(c) (
        Int32,
        UInt32,
        CFArray
    ) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias GetWindow = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    nonisolated(unsafe) private let skyLightHandle: UnsafeMutableRawPointer?
    nonisolated(unsafe) private let accessibilityHandle: UnsafeMutableRawPointer?
    private let connectionID: Int32?
    private let assignToAllSpaces: AssignToAllSpaces?
    private let copySpacesForWindows: CopySpacesForWindows?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces?
    private let getWindow: GetWindow?

    init() {
        let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let applicationServicesPath = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        let skyLightHandle = dlopen(skyLightPath, RTLD_LAZY | RTLD_LOCAL)
        let accessibilityHandle = dlopen(applicationServicesPath, RTLD_LAZY | RTLD_LOCAL)
        self.skyLightHandle = skyLightHandle
        self.accessibilityHandle = accessibilityHandle

        if let skyLightHandle,
           let mainSymbol = dlsym(skyLightHandle, "SLSMainConnectionID")
            ?? dlsym(skyLightHandle, "CGSMainConnectionID") {
            let mainConnection = unsafeBitCast(mainSymbol, to: MainConnection.self)
            connectionID = mainConnection()
        } else {
            connectionID = nil
        }
        assignToAllSpaces = skyLightHandle
            .flatMap { dlsym($0, "SLSProcessAssignToAllSpaces") }
            .map { unsafeBitCast($0, to: AssignToAllSpaces.self) }
        copySpacesForWindows = skyLightHandle
            .flatMap { dlsym($0, "SLSCopySpacesForWindows") ?? dlsym($0, "CGSCopySpacesForWindows") }
            .map { unsafeBitCast($0, to: CopySpacesForWindows.self) }
        copyManagedDisplaySpaces = skyLightHandle
            .flatMap { dlsym($0, "SLSCopyManagedDisplaySpaces") ?? dlsym($0, "CGSCopyManagedDisplaySpaces") }
            .map { unsafeBitCast($0, to: CopyManagedDisplaySpaces.self) }
        getWindow = accessibilityHandle
            .flatMap { dlsym($0, "_AXUIElementGetWindow") }
            .map { unsafeBitCast($0, to: GetWindow.self) }
    }

    deinit {
        if let skyLightHandle { dlclose(skyLightHandle) }
        if let accessibilityHandle { dlclose(accessibilityHandle) }
    }

    var privateAssignmentIsAvailable: Bool {
        connectionID != nil && assignToAllSpaces != nil
    }

    var canVerifyMembership: Bool {
        connectionID != nil && copySpacesForWindows != nil && getWindow != nil
    }

    func ensureAllDesktops(
        application: NSRunningApplication,
        window: AXUIElement,
        target: TargetApplication
    ) async throws -> SpaceAssignmentOutcome {
        if spaceCount(for: window).map({ $0 > 1 }) == true {
            return .alreadyAssigned
        }

        var privateFailure: SpaceAssignmentError?
        if let connectionID, let assignToAllSpaces {
            let result = assignToAllSpaces(connectionID, application.processIdentifier)
            if result == 0 {
                if ordinaryDesktopCount() <= 1 || !canVerifyMembership {
                    return .privateAPIUnverified
                }
                if await waitForMultipleSpaces(window, timeout: 0.8) {
                    return .privateAPI
                }
            } else {
                privateFailure = .privateAPIFailed(result)
            }
        } else {
            privateFailure = .privateAPIUnavailable
        }

        do {
            try await assignThroughDock(target: target)
        } catch let error as SpaceAssignmentError {
            if let privateFailure {
                throw SpaceAssignmentError.dockUnavailable(
                    "\(error.localizedDescription); private route also failed: \(privateFailure.localizedDescription)"
                )
            }
            throw error
        }

        let membershipVerified: Bool
        if ordinaryDesktopCount() <= 1 || !canVerifyMembership {
            membershipVerified = true
        } else {
            membershipVerified = await waitForMultipleSpaces(window, timeout: 1.2)
        }
        guard membershipVerified else {
            throw SpaceAssignmentError.verificationFailed
        }
        return .dockMenu
    }

    private func waitForMultipleSpaces(
        _ window: AXUIElement,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if spaceCount(for: window).map({ $0 > 1 }) == true { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return spaceCount(for: window).map({ $0 > 1 }) == true
    }

    private func spaceCount(for window: AXUIElement) -> Int? {
        guard let connectionID, let copySpacesForWindows, let getWindow else { return nil }
        var windowID: CGWindowID = 0
        guard getWindow(window, &windowID) == .success, windowID != 0 else { return nil }
        let input = [NSNumber(value: windowID)] as CFArray
        guard let value = copySpacesForWindows(connectionID, 0x7, input)?.takeRetainedValue(),
              let spaces = value as? [NSNumber] else {
            return nil
        }
        return spaces.count
    }

    private func ordinaryDesktopCount() -> Int {
        guard let connectionID, let copyManagedDisplaySpaces,
              let value = copyManagedDisplaySpaces(connectionID)?.takeRetainedValue(),
              let displays = value as? [[String: Any]] else {
            return 0
        }
        return displays.reduce(into: 0) { count, display in
            guard let spaces = display["Spaces"] as? [[String: Any]] else { return }
            count += spaces.filter { (($0["type"] as? NSNumber)?.intValue ?? 0) == 0 }.count
        }
    }

    private func assignThroughDock(target: TargetApplication) async throws {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            throw SpaceAssignmentError.dockUnavailable("Dock is not running")
        }
        let dockRoot = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockRoot, 0.7)
        guard let dockItem = descendants(of: dockRoot, maximumDepth: 5).first(where: {
            guard copyAXAttribute($0, kAXRoleAttribute) as? String == "AXDockItem" else { return false }
            if let url = copyAXAttribute($0, kAXURLAttribute) as? URL {
                return url.standardizedFileURL == target.url.standardizedFileURL
            }
            if let urlString = copyAXAttribute($0, kAXURLAttribute) as? String,
               let url = URL(string: urlString) {
                return url.standardizedFileURL == target.url.standardizedFileURL
            }
            return copyAXAttribute($0, kAXTitleAttribute) as? String == target.name
        }) else {
            throw SpaceAssignmentError.dockUnavailable("could not find \(target.name)'s Dock item")
        }
        guard AXUIElementPerformAction(dockItem, kAXShowMenuAction as CFString) == .success else {
            throw SpaceAssignmentError.dockUnavailable("could not open \(target.name)'s Dock menu")
        }

        let titles = dockMenuTitles()
        guard let optionsItem = await waitForMenuItem(
            named: titles.options,
            in: dockRoot,
            timeout: 0.8
        ) else {
            dismissMenu()
            throw SpaceAssignmentError.dockUnavailable("the Options menu item was not exposed")
        }

        if await waitForMenuItem(named: titles.allDesktops, in: dockRoot, timeout: 0.15) == nil {
            let actions = copyAXActions(optionsItem)
            let action = actions.contains(kAXShowMenuAction) ? kAXShowMenuAction : kAXPressAction
            guard AXUIElementPerformAction(optionsItem, action as CFString) == .success else {
                dismissMenu()
                throw SpaceAssignmentError.dockUnavailable("could not open the Options submenu")
            }
        }

        guard let allDesktopsItem = await waitForMenuItem(
            named: titles.allDesktops,
            in: dockRoot,
            timeout: 0.8
        ), boolAXAttribute(allDesktopsItem, kAXEnabledAttribute) else {
            dismissMenu()
            throw SpaceAssignmentError.dockUnavailable(
                "the All Desktops item was unavailable; macOS only exposes it when multiple Desktops exist"
            )
        }
        guard AXUIElementPerformAction(allDesktopsItem, kAXPressAction as CFString) == .success else {
            dismissMenu()
            throw SpaceAssignmentError.dockUnavailable("macOS rejected the All Desktops menu action")
        }
    }

    private func dockMenuTitles() -> (options: String, allDesktops: String) {
        guard let bundle = Bundle(path: "/System/Library/CoreServices/Dock.app") else {
            return ("Options", "All Desktops")
        }
        return (
            bundle.localizedString(forKey: "OPTIONS", value: "Options", table: "DockMenus"),
            bundle.localizedString(forKey: "ALL_DESKTOPS", value: "All Desktops", table: "DockMenus")
        )
    }

    private func waitForMenuItem(
        named title: String,
        in dockRoot: AXUIElement,
        timeout: TimeInterval
    ) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let item = descendants(of: dockRoot, maximumDepth: 9).first(where: {
                copyAXAttribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole
                    && copyAXAttribute($0, kAXTitleAttribute) as? String == title
            }) {
                return item
            }
            try? await Task.sleep(for: .milliseconds(35))
        }
        return nil
    }

    private func descendants(of root: AXUIElement, maximumDepth: Int) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        while cursor < queue.count && cursor < 2_000 {
            let (element, depth) = queue[cursor]
            cursor += 1
            result.append(element)
            if depth < maximumDepth,
               let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return result
    }

    private func copyAXActions(_ element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private func dismissMenu() {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: false) else {
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private struct FocusedWindow {
    let application: NSRunningApplication
    let element: AXUIElement
}

private final class HotKeyController {
    private static let signature: OSType = 0x4154_5350 // ATSP
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void

    init(shortcut: Shortcut, onPress: @escaping () -> Void) throws {
        self.onPress = onPress
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            scratchpadHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr else {
            throw PrototypeError.hotKey("Could not install the hotkey handler (\(handlerStatus))")
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard registrationStatus == noErr, let reference else {
            if let handler { RemoveEventHandler(handler) }
            throw PrototypeError.hotKey("Could not register \(shortcut.description) (\(registrationStatus)); another app may already own it")
        }
        self.reference = reference
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    func receive() {
        onPress()
    }
}

private func scratchpadHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == 0x4154_5350, identifier.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }
    Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue().receive()
    return noErr
}

@MainActor
private final class ScratchpadController {
    private let target: TargetApplication
    private let placement: Placement
    private let shortcut: Shortcut
    private let automaticallyAssignAllDesktops: Bool
    private let spaceAssignment: SpaceAssignmentCoordinator
    private var hotKey: HotKeyController?
    private var previousFocus: FocusedWindow?
    private var scratchpadWindow: AXUIElement?
    private var operationInProgress = false

    init(
        target: TargetApplication,
        placement: Placement,
        shortcut: Shortcut,
        automaticallyAssignAllDesktops: Bool,
        spaceAssignment: SpaceAssignmentCoordinator
    ) {
        self.target = target
        self.placement = placement
        self.shortcut = shortcut
        self.automaticallyAssignAllDesktops = automaticallyAssignAllDesktops
        self.spaceAssignment = spaceAssignment
    }

    func start() throws {
        hotKey = try HotKeyController(shortcut: shortcut) { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleToggle()
            }
        }
        print("Scratchpad ready: \(target.name) → \(placement.rawValue)")
        print("Press \(shortcut.description) to show or hide it. Control-C exits.")
        print(automaticallyAssignAllDesktops
            ? "All Desktops assignment will be applied and verified automatically."
            : "Automatic All Desktops assignment is disabled.")
    }

    private func scheduleToggle() {
        guard !operationInProgress else {
            print("Scratchpad is still settling; ignored repeated shortcut.")
            return
        }
        operationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.toggle()
            self.operationInProgress = false
        }
    }

    private func toggle() async {
        if let running = runningApplication(),
           !running.isHidden,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier {
            hide(running)
        } else {
            await show()
        }
    }

    private func show() async {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != target.bundleIdentifier,
           let window = focusedWindow(for: frontmost) {
            previousFocus = FocusedWindow(application: frontmost, element: window)
        } else {
            previousFocus = nil
        }

        let application: NSRunningApplication
        do {
            if let running = runningApplication() {
                application = running
            } else {
                application = try await launchTarget()
            }
        } catch {
            print("Show failed: could not launch \(target.name): \(error.localizedDescription)")
            return
        }

        if !application.unhide() {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            _ = AXUIElementSetAttributeValue(
                appElement,
                kAXHiddenAttribute as CFString,
                kCFBooleanFalse
            )
        }
        _ = application.activate(options: [.activateAllWindows])

        let deadline = Date().addingTimeInterval(4)
        var window: AXUIElement?
        while Date() < deadline {
            if let remembered = scratchpadWindow, isUsable(remembered) {
                window = remembered
            } else {
                window = preferredWindow(for: application)
            }
            if window != nil { break }
            try? await Task.sleep(for: .milliseconds(60))
        }
        guard var window else {
            print("Show failed: \(target.name) did not expose a standard window within four seconds.")
            return
        }
        scratchpadWindow = window

        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = application.activate(options: [])

        let focusDeadline = Date().addingTimeInterval(1)
        while Date() < focusDeadline && !isFocused(window, in: application) {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard isFocused(window, in: application) else {
            print("Show failed: \(target.name)'s selected window did not become focused.")
            return
        }

        if automaticallyAssignAllDesktops {
            do {
                let outcome = try await spaceAssignment.ensureAllDesktops(
                    application: application,
                    window: window,
                    target: target
                )
                print("\(outcome.message).")
            } catch {
                print("Automatic All Desktops assignment failed: \(error.localizedDescription)")
            }

            if let refreshedWindow = preferredWindow(for: application) {
                window = refreshedWindow
                scratchpadWindow = refreshedWindow
            }
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = application.activate(options: [])
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let refocusDeadline = Date().addingTimeInterval(0.8)
            while Date() < refocusDeadline && !isFocused(window, in: application) {
                try? await Task.sleep(for: .milliseconds(35))
            }
        }

        do {
            let metrics = try NativeMenuDispatcher.dispatch(
                identifier: placement.menuIdentifier,
                commandName: placement.rawValue,
                processID: application.processIdentifier,
                window: window
            )
            print(String(format: "Shown and placed \(target.name) in %.1f ms.", metrics.totalMilliseconds))
        } catch {
            print("Shown \(target.name), but native placement was unavailable: \(error.localizedDescription)")
        }
    }

    private func hide(_ application: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let hidden = application.hide() || AXUIElementSetAttributeValue(
            appElement,
            kAXHiddenAttribute as CFString,
            kCFBooleanTrue
        ) == .success
        guard hidden else {
            print("Hide failed: macOS refused to hide \(target.name).")
            return
        }
        print("Hidden \(target.name).")
        guard let previousFocus else { return }
        self.previousFocus = nil
        guard !previousFocus.application.isTerminated, isUsable(previousFocus.element) else { return }
        _ = AXUIElementSetAttributeValue(
            previousFocus.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = previousFocus.application.activate(options: [])
        _ = AXUIElementPerformAction(previousFocus.element, kAXRaiseAction as CFString)
    }

    private func runningApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier)
            .first(where: { !$0.isTerminated })
    }

    private func launchTarget() async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let processID: pid_t = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: target.url,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(returning: application.processIdentifier)
                } else {
                    continuation.resume(throwing: PrototypeError.applicationNotFound(self.target.bundleIdentifier))
                }
            }
        }
        guard let launched = NSRunningApplication(processIdentifier: processID) else {
            throw PrototypeError.applicationNotFound(target.bundleIdentifier)
        }
        return launched
    }

    private func preferredWindow(for application: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        if let focused = copyAXAttribute(appElement, kAXFocusedWindowAttribute),
           CFGetTypeID(focused) == AXUIElementGetTypeID(),
           isUsable(unsafeDowncast(focused, to: AXUIElement.self)) {
            return unsafeDowncast(focused, to: AXUIElement.self)
        }
        guard let windows = copyAXAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else {
            return nil
        }
        return windows.first(where: isUsable)
    }

    private func focusedWindow(for application: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let value = copyAXAttribute(appElement, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func isUsable(_ window: AXUIElement) -> Bool {
        guard copyAXAttribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
              copyAXAttribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              !boolAXAttribute(window, kAXMinimizedAttribute),
              !boolAXAttribute(window, "AXFullScreen") else {
            return false
        }
        return true
    }

    private func isFocused(_ window: AXUIElement, in application: NSRunningApplication) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let focused = focusedWindow(for: application) else {
            return false
        }
        return CFEqual(focused, window)
    }
}

@MainActor
private func run() throws {
    setbuf(stdout, nil)
    let options = try Options.parse(CommandLine.arguments)
    let spaceAssignment = SpaceAssignmentCoordinator()
    if options.probe {
        let hotKeyProbe = try HotKeyController(shortcut: options.shortcut) {}
        print("Configuration valid:")
        print("  app=\(options.target.name) [\(options.target.bundleIdentifier)]")
        print("  path=\(options.target.url.path)")
        print("  placement=\(options.placement.rawValue)")
        print("  shortcut=\(options.shortcut.description)")
        print("  shortcutRegistration=available")
        print("  automaticAllDesktops=\(options.automaticallyAssignAllDesktops)")
        print("  privateAllDesktopsFunction=\(spaceAssignment.privateAssignmentIsAvailable ? "available" : "unavailable")")
        print("  membershipVerification=\(spaceAssignment.canVerifyMembership ? "available" : "unavailable")")
        withExtendedLifetime(hotKeyProbe) {}
        return
    }
    guard accessibilityIsTrusted(requestIfNeeded: options.requestAccessibility) else {
        throw PrototypeError.accessibilityPermission
    }
    let processLock = try SingletonProcessLock()
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let controller = ScratchpadController(
        target: options.target,
        placement: options.placement,
        shortcut: options.shortcut,
        automaticallyAssignAllDesktops: options.automaticallyAssignAllDesktops,
        spaceAssignment: spaceAssignment
    )
    try controller.start()
    withExtendedLifetime((controller, processLock)) {
        application.run()
    }
}

do {
    try run()
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
