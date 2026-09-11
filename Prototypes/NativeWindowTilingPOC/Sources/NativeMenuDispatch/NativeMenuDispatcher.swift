import AppKit
import ApplicationServices
import Foundation

public enum NativeMenuDispatchError: LocalizedError, Equatable {
    case targetNotFrontmost
    case commandMissing(String)
    case commandUnavailable(String)
    case focusedWindowChanged
    case accessibilityFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .targetNotFrontmost:
            "Target lost foreground focus; no menu action was sent"
        case let .commandMissing(name):
            "This app does not expose the native \(name) menu command"
        case let .commandUnavailable(name):
            "Native \(name) is unavailable for this window"
        case .focusedWindowChanged:
            "Focused window changed during discovery; no menu action was sent"
        case let .accessibilityFailure(code):
            "Native menu action failed with Accessibility error \(code)"
        }
    }
}

public struct NativeMenuDispatchMetrics: Sendable {
    public let totalMilliseconds: Double
    public let dispatchMilliseconds: Double
}

public enum NativeMenuDispatcher {
    /// Finds a semantic Window-menu item without opening menus or matching a
    /// localized title, validates its exact target window, then invokes AXPress.
    @MainActor
    public static func dispatch(
        identifier: String,
        commandName: String,
        processID: pid_t,
        window: AXUIElement
    ) throws -> NativeMenuDispatchMetrics {
        let started = ProcessInfo.processInfo.systemUptime
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
            throw NativeMenuDispatchError.targetNotFrontmost
        }
        guard let item = menuItem(processID: processID, identifier: identifier) else {
            throw NativeMenuDispatchError.commandMissing(commandName)
        }

        var actions: CFArray?
        let actionError = AXUIElementCopyActionNames(item, &actions)
        guard copyAttribute(item, kAXEnabledAttribute) as? Bool == true,
              actionError == .success,
              (actions as? [String])?.contains(kAXPressAction) == true else {
            throw NativeMenuDispatchError.commandUnavailable(commandName)
        }

        let application = AXUIElementCreateApplication(processID)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let focused = copyAttribute(application, kAXFocusedWindowAttribute),
              CFEqual(focused, window) else {
            throw NativeMenuDispatchError.focusedWindowChanged
        }

        let dispatchStarted = ProcessInfo.processInfo.systemUptime
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        let ended = ProcessInfo.processInfo.systemUptime
        guard result == .success else {
            throw NativeMenuDispatchError.accessibilityFailure(result.rawValue)
        }
        return NativeMenuDispatchMetrics(
            totalMilliseconds: (ended - started) * 1_000,
            dispatchMilliseconds: (ended - dispatchStarted) * 1_000
        )
    }

    private static func menuItem(processID: pid_t, identifier: String) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 2)
        guard let menuBar = copyAttribute(application, kAXMenuBarAttribute),
              CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
            return nil
        }

        var queue: [(AXUIElement, Int)] = [(unsafeDowncast(menuBar, to: AXUIElement.self), 0)]
        var cursor = 0
        while cursor < queue.count && cursor < 2_000 {
            let (element, depth) = queue[cursor]
            cursor += 1
            if copyAttribute(element, kAXIdentifierAttribute) as? String == identifier {
                return element
            }
            if depth < 7, let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
