import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

private struct ApplicationDiscoveryError: LocalizedError {
    let value: String
    var errorDescription: String? { "Could not find application: \(value)" }
}

public struct TargetApplication: Sendable {
    public let url: URL
    public let bundleIdentifier: String
    public let name: String

    @MainActor
    public static func resolve(_ value: String) throws -> TargetApplication {
        let url: URL?
        if value.contains("/") {
            url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        } else if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) {
            url = bundleURL
        } else {
            url = applicationURL(named: value)
        }
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else {
            throw ApplicationDiscoveryError(value: value)
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

public enum SpaceAssignmentOutcome {
    case alreadyAssigned
    case privateAPI
    case privateAPIUnverified
    case dockMenu

    public var message: String {
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
            "macOS did not report the window on the required Desktops after either assignment route"
        }
    }
}

/// Applies session-level process assignment through SkyLight first, then uses
/// the user's native Dock menu as a persistent fallback. Every private symbol is
/// resolved at runtime, and a multi-Space membership read verifies the result.
@MainActor
public final class SpaceAssignmentCoordinator {
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

    public init() {
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

    public var privateAssignmentIsAvailable: Bool {
        connectionID != nil && assignToAllSpaces != nil
    }

    public var canVerifyMembership: Bool {
        connectionID != nil && copySpacesForWindows != nil && getWindow != nil
    }

    public func ensureAllDesktops(
        application: NSRunningApplication,
        window: AXUIElement,
        target: TargetApplication,
        requiredSpaceIDs: Set<String>? = nil
    ) async throws -> SpaceAssignmentOutcome {
        func verified() -> Bool {
            if let requiredSpaceIDs {
                return requiredSpaceIDs.isSubset(of: spaceIDs(for: window) ?? [])
            }
            return spaceCount(for: window).map({ $0 > 1 }) == true
        }
        // Membership in one Desktop cannot establish a sticky assignment.
        if (requiredSpaceIDs?.count ?? 2) > 1 && verified() {
            return .alreadyAssigned
        }

        var privateFailure: SpaceAssignmentError?
        if let connectionID, let assignToAllSpaces {
            let result = assignToAllSpaces(connectionID, application.processIdentifier)
            if result == 0 {
                if ordinaryDesktopCount() <= 1 || !canVerifyMembership {
                    return .privateAPIUnverified
                }
                if await waitForMembership(timeout: 0.8, verified: verified) {
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
            membershipVerified = await waitForMembership(timeout: 1.2, verified: verified)
        }
        guard membershipVerified else {
            throw SpaceAssignmentError.verificationFailed
        }
        return .dockMenu
    }

    private func waitForMembership(
        timeout: TimeInterval,
        verified: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if verified() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return verified()
    }

    private func spaceCount(for window: AXUIElement) -> Int? {
        spaceIDs(for: window)?.count
    }

    private func spaceIDs(for window: AXUIElement) -> Set<String>? {
        guard let connectionID, let copySpacesForWindows, let getWindow else { return nil }
        var windowID: CGWindowID = 0
        guard getWindow(window, &windowID) == .success, windowID != 0 else { return nil }
        let input = [NSNumber(value: windowID)] as CFArray
        guard let value = copySpacesForWindows(connectionID, 0x7, input)?.takeRetainedValue(),
              let spaces = value as? [NSNumber] else {
            return nil
        }
        return Set(spaces.map(\.stringValue))
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
