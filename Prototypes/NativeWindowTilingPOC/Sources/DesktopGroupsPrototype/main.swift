import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import DesktopGroupsCore
import Foundation
import NativeMenuDispatch

private enum PrototypeError: LocalizedError {
    case accessibilityPermission
    case alreadyRunning
    case privateAPI(String)
    case hotKey(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermission:
            "Accessibility permission is required. Enable the terminal running this prototype in System Settings > Privacy & Security > Accessibility."
        case .alreadyRunning:
            "Another Desktop Groups manager is already running for this user"
        case let .privateAPI(message), let .hotKey(message):
            message
        }
    }
}

/// Carbon registrations are process-local, so overlapping prototype processes
/// can otherwise survive a runner timeout and compete for the same shortcuts.
private final class SingletonProcessLock {
    private let descriptor: Int32

    init() throws {
        let path = "/tmp/com.elevenideas.atelier.desktop-groups.\(getuid()).lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw PrototypeError.privateAPI("Could not open the Desktop Groups process lock")
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

private struct Options {
    let requestAccessibility: Bool
    let probe: Bool

    static func parse(_ arguments: [String]) -> Options {
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            Usage: desktop-groups-prototype [--request-accessibility] [--probe]

              Cmd-Opt-G        Group or repair the focused window's Desktop
              Cmd-Opt-1…9     Select members 1…9
              Cmd-Opt-0       Select member 10
              Cmd-Opt-[ / ]   Select previous / next member

            State is intentionally session-only. Control-C exits.

              --probe          Print current display/Space identity and exit
            """)
            exit(EXIT_SUCCESS)
        }
        return Options(
            requestAccessibility: arguments.contains("--request-accessibility"),
            probe: arguments.contains("--probe")
        )
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

private final class AXWindowIdentity {
    private typealias GetWindow = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private let handle: UnsafeMutableRawPointer
    private let getWindow: GetWindow

    init() throws {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            throw PrototypeError.privateAPI("Could not open ApplicationServices")
        }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            dlclose(handle)
            throw PrototypeError.privateAPI("ApplicationServices no longer exports _AXUIElementGetWindow")
        }
        self.handle = handle
        self.getWindow = unsafeBitCast(symbol, to: GetWindow.self)
    }

    deinit {
        dlclose(handle)
    }

    func windowID(for element: AXUIElement) -> CGWindowID? {
        var identifier: CGWindowID = 0
        return getWindow(element, &identifier) == .success && identifier != 0 ? identifier : nil
    }
}

private final class SpaceReader {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (
        Int32,
        UInt32,
        CFArray
    ) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private let handle: UnsafeMutableRawPointer
    private let connectionID: Int32
    private let copySpacesForWindows: CopySpacesForWindows
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces

    init() throws {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            throw PrototypeError.privateAPI("Could not open SkyLight.framework")
        }
        guard let mainSymbol = dlsym(handle, "SLSMainConnectionID")
                ?? dlsym(handle, "CGSMainConnectionID"),
              let windowSpacesSymbol = dlsym(handle, "SLSCopySpacesForWindows")
                ?? dlsym(handle, "CGSCopySpacesForWindows"),
              let managedSpacesSymbol = dlsym(handle, "SLSCopyManagedDisplaySpaces")
                ?? dlsym(handle, "CGSCopyManagedDisplaySpaces") else {
            dlclose(handle)
            throw PrototypeError.privateAPI("Required read-only SkyLight Space symbols are unavailable")
        }

        let mainConnection = unsafeBitCast(mainSymbol, to: MainConnection.self)
        self.handle = handle
        self.connectionID = mainConnection()
        self.copySpacesForWindows = unsafeBitCast(windowSpacesSymbol, to: CopySpacesForWindows.self)
        self.copyManagedDisplaySpaces = unsafeBitCast(
            managedSpacesSymbol,
            to: CopyManagedDisplaySpaces.self
        )
    }

    deinit {
        dlclose(handle)
    }

    /// A count other than one is deliberately rejected. Besides ambiguity,
    /// multiple returned Spaces are how established callers identify sticky
    /// (All Desktops) windows.
    func singleSpace(for windowID: CGWindowID) -> UInt64? {
        let input = [NSNumber(value: windowID)] as CFArray
        guard let value = copySpacesForWindows(connectionID, 0x7, input)?.takeRetainedValue(),
              let spaces = value as? [NSNumber],
              spaces.count == 1 else {
            return nil
        }
        return spaces[0].uint64Value
    }

    func currentSpacesByDisplay() -> [String: UInt64] {
        guard let value = copyManagedDisplaySpaces(connectionID)?.takeRetainedValue(),
              let displays = value as? [[String: Any]] else {
            return [:]
        }

        var result: [String: UInt64] = [:]
        for display in displays {
            guard let rawDisplayID = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  let spaceID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value
                    ?? (current["id64"] as? NSNumber)?.uint64Value else {
                continue
            }
            let displayID = rawDisplayID == "Main" ? Self.mainDisplayID() : rawDisplayID.uppercased()
            result[displayID] = spaceID
        }
        return result
    }

    static func displayID(for display: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else {
            return String(display)
        }
        return (string as String).uppercased()
    }

    private static func mainDisplayID() -> String {
        displayID(for: CGMainDisplayID())
    }
}

private struct WindowRecord {
    let key: WindowKey
    let groupKey: GroupKey
    let element: AXUIElement
    let bounds: CGRect
    let title: String
}

@MainActor
private final class WindowInventory {
    private let identity: AXWindowIdentity
    private let spaces: SpaceReader
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier

    init(identity: AXWindowIdentity, spaces: SpaceReader) {
        self.identity = identity
        self.spaces = spaces
    }

    /// Core Graphics supplies front-to-back ordering; Accessibility supplies
    /// semantic eligibility. The private AX function is the only join—there is
    /// intentionally no title/frame heuristic fallback.
    func visibleEligibleWindows() -> [WindowRecord] {
        guard let descriptions = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let candidates: [(CGWindowID, pid_t, CGRect)] = descriptions.compactMap { description in
            guard let processID = (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  processID != ownProcessID,
                  (description[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (description[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let windowID = (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDictionary = description[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width > 1,
                  bounds.height > 1 else {
                return nil
            }
            return (windowID, processID, bounds)
        }

        var elementsByProcess: [pid_t: [CGWindowID: AXUIElement]] = [:]
        for processID in Set(candidates.map(\.1)) {
            guard let running = NSRunningApplication(processIdentifier: processID), !running.isHidden else {
                continue
            }
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 0.35)
            guard let windows = copyAXAttribute(application, kAXWindowsAttribute) as? [AXUIElement] else {
                continue
            }
            var mapped: [CGWindowID: AXUIElement] = [:]
            for window in windows where isEligible(window) {
                if let windowID = identity.windowID(for: window) {
                    mapped[windowID] = window
                }
            }
            elementsByProcess[processID] = mapped
        }

        return candidates.compactMap { windowID, processID, bounds in
            guard let element = elementsByProcess[processID]?[windowID],
                  let spaceID = spaces.singleSpace(for: windowID),
                  let displayID = displayID(containing: bounds) else {
                return nil
            }
            let title = copyAXAttribute(element, kAXTitleAttribute) as? String ?? "Untitled"
            return WindowRecord(
                key: WindowKey(processID: processID, windowID: windowID),
                groupKey: GroupKey(spaceID: spaceID, displayID: displayID),
                element: element,
                bounds: bounds,
                title: title
            )
        }
    }

    func focusedWindow(in records: [WindowRecord]) -> WindowRecord? {
        guard let running = NSWorkspace.shared.frontmostApplication,
              running.processIdentifier != ownProcessID else {
            return nil
        }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        guard let focused = copyAXAttribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(),
              let windowID = identity.windowID(for: unsafeDowncast(focused, to: AXUIElement.self)) else {
            return nil
        }
        return records.first { $0.key.processID == running.processIdentifier && $0.key.windowID == windowID }
    }

    func record(for key: WindowKey, in records: [WindowRecord]) -> WindowRecord? {
        records.first { $0.key == key }
    }

    private func isEligible(_ window: AXUIElement) -> Bool {
        guard copyAXAttribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
              copyAXAttribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              copyAXAttribute(window, kAXMinimizedAttribute) as? Bool != true,
              copyAXAttribute(window, "AXFullScreen") as? Bool != true else {
            return false
        }
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            window,
            kAXPositionAttribute as CFString,
            &positionSettable
        ) == .success,
        AXUIElementIsAttributeSettable(
            window,
            kAXSizeAttribute as CFString,
            &sizeSettable
        ) == .success else {
            return false
        }
        return positionSettable.boolValue && sizeSettable.boolValue
    }

    private func displayID(containing bounds: CGRect) -> String? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            return nil
        }
        return displays.prefix(Int(count))
            .map { ($0, CGDisplayBounds($0).intersection(bounds).area) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }
            .map { SpaceReader.displayID(for: $0.0) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private enum HotKeyCommand: Sendable {
    case group
    case index(Int)
    case offset(Int)
}

private final class HotKeyController {
    private static let signature: OSType = 0x4154_4752 // ATGR
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    let onCommand: @Sendable (HotKeyCommand) -> Void

    init(onCommand: @escaping @Sendable (HotKeyCommand) -> Void) throws {
        self.onCommand = onCommand
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            desktopGroupHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else {
            throw PrototypeError.hotKey("Could not install Carbon hotkey handler (\(status))")
        }

        try register(id: 1, keyCode: UInt32(kVK_ANSI_G))
        let digitKeys: [(Int, Int)] = [
            (kVK_ANSI_1, 0), (kVK_ANSI_2, 1), (kVK_ANSI_3, 2), (kVK_ANSI_4, 3),
            (kVK_ANSI_5, 4), (kVK_ANSI_6, 5), (kVK_ANSI_7, 6), (kVK_ANSI_8, 7),
            (kVK_ANSI_9, 8), (kVK_ANSI_0, 9),
        ]
        for (keyCode, index) in digitKeys {
            try register(id: UInt32(10 + index), keyCode: UInt32(keyCode))
        }
        try register(id: 30, keyCode: UInt32(kVK_ANSI_LeftBracket))
        try register(id: 31, keyCode: UInt32(kVK_ANSI_RightBracket))
    }

    deinit {
        references.forEach { _ = UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }

    func receive(id: UInt32) {
        switch id {
        case 1: onCommand(.group)
        case 10...19: onCommand(.index(Int(id - 10)))
        case 30: onCommand(.offset(-1))
        case 31: onCommand(.offset(1))
        default: break
        }
    }

    private func register(id: UInt32, keyCode: UInt32) throws {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let modifiers = UInt32(cmdKey | optionKey)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw PrototypeError.hotKey("Could not register Cmd-Opt hotkey id \(id) (\(status))")
        }
        references.append(reference)
    }
}

private func desktopGroupHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == 0x4154_4752 else {
        return OSStatus(eventNotHandledErr)
    }
    Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue().receive(id: hotKeyID.id)
    return noErr
}

private final class AXObserverContext: @unchecked Sendable {
    weak var controller: DesktopGroupController?
    init(controller: DesktopGroupController) { self.controller = controller }
}

private func desktopGroupAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let context = Unmanaged<AXObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    let notificationName = notification as String
    Task { @MainActor in
        context.controller?.handleAccessibilityChange(notificationName)
    }
}

@MainActor
private final class AXObservationHub {
    private struct Entry {
        let observer: AXObserver
        let context: AXObserverContext
        var windows: Set<WindowKey>
    }

    private weak var controller: DesktopGroupController?
    private var entries: [pid_t: Entry] = [:]

    init(controller: DesktopGroupController) {
        self.controller = controller
    }

    func sync(applications: [NSRunningApplication], records: [WindowRecord]) {
        let liveProcesses = Set(applications.map(\.processIdentifier))
        for processID in entries.keys where !liveProcesses.contains(processID) {
            remove(processID: processID)
        }

        for application in applications
        where application.processIdentifier != getpid() && application.activationPolicy != .prohibited {
            installApplicationObserverIfNeeded(processID: application.processIdentifier)
        }

        let visibleKeys = Set(records.map(\.key))
        for processID in entries.keys {
            entries[processID]?.windows.formIntersection(visibleKeys)
        }

        for record in records {
            guard var entry = entries[record.key.processID], !entry.windows.contains(record.key) else {
                continue
            }
            let context = Unmanaged.passUnretained(entry.context).toOpaque()
            for notification in [
                kAXUIElementDestroyedNotification,
                kAXMovedNotification,
                kAXResizedNotification,
                kAXWindowMiniaturizedNotification,
                kAXWindowDeminiaturizedNotification,
            ] {
                AXObserverAddNotification(entry.observer, record.element, notification as CFString, context)
            }
            entry.windows.insert(record.key)
            entries[record.key.processID] = entry
        }
    }

    private func installApplicationObserverIfNeeded(processID: pid_t) {
        guard entries[processID] == nil, let controller else { return }
        var observer: AXObserver?
        guard AXObserverCreate(processID, desktopGroupAXObserverCallback, &observer) == .success,
              let observer else {
            return
        }
        let context = AXObserverContext(controller: controller)
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        let application = AXUIElementCreateApplication(processID)
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, application, notification as CFString, opaque)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            CFRunLoopMode.defaultMode
        )
        entries[processID] = Entry(observer: observer, context: context, windows: [])
    }

    private func remove(processID: pid_t) {
        guard let entry = entries.removeValue(forKey: processID) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(entry.observer),
            CFRunLoopMode.defaultMode
        )
    }
}

@MainActor
private final class DesktopGroupController {
    private let spaces: SpaceReader
    private let inventory: WindowInventory
    private var store = GroupStore()
    private var latestRecords: [WindowRecord] = []
    private var filledFrames: [WindowKey: CGRect] = [:]
    private var hotKeys: HotKeyController?
    private var observations: AXObservationHub?
    private var timer: Timer?
    private var operation: Task<Void, Never>?
    private var reconcileScheduled = false

    init(spaces: SpaceReader, identity: AXWindowIdentity) {
        self.spaces = spaces
        self.inventory = WindowInventory(identity: identity, spaces: spaces)
    }

    func start() throws {
        let hotKeys = try HotKeyController { [weak self] command in
            Task { @MainActor in self?.handle(command) }
        }
        self.hotKeys = hotKeys
        self.observations = AXObservationHub(controller: self)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationsChanged),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationsChanged),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        reconcile()
        print("ATE-14 Desktop Groups is running. Press Cmd-Opt-G to group this Desktop.")
        print("Member keys: Cmd-Opt-1…9, Cmd-Opt-0 (10), Cmd-Opt-[ / ]. Control-C exits.")
    }

    @objc private func workspaceApplicationsChanged(_ notification: Notification) {
        scheduleReconcile()
    }

    @objc private func activeSpaceChanged(_ notification: Notification) {
        scheduleReconcile()
    }

    func handleAccessibilityChange(_ notification: String) {
        scheduleReconcile()
    }

    private func handle(_ command: HotKeyCommand) {
        operation?.cancel()
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            switch command {
            case .group: await createOrRepairGroup()
            case let .index(index): await select(index: index)
            case let .offset(offset): await select(offset: offset)
            }
        }
    }

    private func createOrRepairGroup() async {
        reconcile()
        guard let focused = inventory.focusedWindow(in: latestRecords) else {
            print("Group failed: the focused window is not eligible.")
            return
        }
        let candidates = latestRecords.filter { $0.groupKey == focused.groupKey }.map(\.key)
        let group = store.createOrRepair(
            key: focused.groupKey,
            focused: focused.key,
            eligibleFrontToBack: candidates
        )
        print("Grouped \(focused.groupKey): \(group.members.count) member(s)")
        printMembers(group, records: latestRecords)

        // Native menu dispatch requires foreground focus. Walking the initial
        // group backward makes the original member the final Fill target.
        for member in group.members.reversed() {
            guard !Task.isCancelled else { return }
            await focusAndMaybeFill(member.key, in: group.key, forceFill: true)
        }
    }

    private func select(index: Int) async {
        guard let key = targetGroupKey() else {
            print("Select failed: no grouped Desktop owns the focused window or pointer display.")
            return
        }
        reconcile(groupKey: key)
        guard let member = store.select(index: index, in: key) else {
            print("Select failed: \(key) has no member \(index + 1).")
            return
        }
        await focusAndMaybeFill(member.key, in: key)
    }

    private func select(offset: Int) async {
        guard let key = targetGroupKey() else {
            print("Select failed: no grouped Desktop owns the focused window or pointer display.")
            return
        }
        reconcile(groupKey: key)
        guard let member = store.select(offset: offset, in: key) else {
            print("Select failed: the group is empty.")
            return
        }
        await focusAndMaybeFill(member.key, in: key)
    }

    private func focusAndMaybeFill(
        _ member: WindowKey,
        in groupKey: GroupKey,
        forceFill: Bool = false
    ) async {
        guard !Task.isCancelled else { return }
        latestRecords = inventory.visibleEligibleWindows()
        guard let record = inventory.record(for: member, in: latestRecords),
              record.groupKey == groupKey else {
            reconcile(groupKey: groupKey)
            print("Member disappeared or left the grouped Desktop: \(member)")
            return
        }
        guard let application = NSRunningApplication(processIdentifier: member.processID) else {
            return
        }

        let mainResult = AXUIElementSetAttributeValue(
            record.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = application.activate(options: [])
        let raiseResult = AXUIElementPerformAction(record.element, kAXRaiseAction as CFString)
        guard mainResult == .success || raiseResult == .success else {
            print("Focus failed for \(member): AXMain=\(mainResult.rawValue) AXRaise=\(raiseResult.rawValue)")
            return
        }

        let focusDeadline = Date().addingTimeInterval(0.7)
        while !isFocused(record), Date() < focusDeadline {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
        }
        guard isFocused(record) else {
            print("Focus failed for \(member): target did not become the exact focused window.")
            return
        }
        _ = store.activate(member, in: groupKey)
        print("Selected member \((store.groups[groupKey]?.activeIndex ?? 0) + 1): \(record.title)")

        let priorFrame = filledFrames[member]
        let movedSinceFill = priorFrame.map { !$0.approximatelyEquals(record.bounds) } ?? true
        let result = store.groups[groupKey]?.members.first { $0.key == member }?.lastFillResult
        let needsFill = forceFill || result == .deferred || result == .notAttempted || movedSinceFill
        guard needsFill, !Task.isCancelled else { return }

        do {
            let metrics = try NativeMenuDispatcher.dispatch(
                identifier: "_zoomFill:",
                commandName: "fill",
                processID: member.processID,
                window: record.element
            )
            store.recordFill(.succeeded, for: member, in: groupKey)
            try? await Task.sleep(for: .milliseconds(650))
            latestRecords = inventory.visibleEligibleWindows()
            filledFrames[member] = inventory.record(for: member, in: latestRecords)?.bounds
            print(String(format: "Fill dispatched in %.1f ms (menu discovery + AXPress).", metrics.totalMilliseconds))
        } catch let error as NativeMenuDispatchError {
            switch error {
            case .commandMissing, .commandUnavailable:
                store.recordFill(.unavailable(error.localizedDescription), for: member, in: groupKey)
            default:
                store.recordFill(.failed(error.localizedDescription), for: member, in: groupKey)
            }
            print("Fill skipped for \(record.title): \(error.localizedDescription)")
        } catch {
            store.recordFill(.failed(error.localizedDescription), for: member, in: groupKey)
            print("Fill failed for \(record.title): \(error.localizedDescription)")
        }
    }

    private func isFocused(_ record: WindowRecord) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == record.key.processID else {
            return false
        }
        let application = AXUIElementCreateApplication(record.key.processID)
        guard let value = copyAXAttribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return false
        }
        return CFEqual(value, record.element)
    }

    private func targetGroupKey() -> GroupKey? {
        latestRecords = inventory.visibleEligibleWindows()
        if let focused = inventory.focusedWindow(in: latestRecords) {
            return store.groups[focused.groupKey] == nil ? nil : focused.groupKey
        }
        guard let point = CGEvent(source: nil)?.location,
              let displayID = displayID(containing: point),
              let spaceID = spaces.currentSpacesByDisplay()[displayID] else {
            return nil
        }
        let key = GroupKey(spaceID: spaceID, displayID: displayID)
        return store.groups[key] == nil ? nil : key
    }

    private func displayID(containing point: CGPoint) -> String? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else {
            return nil
        }
        return SpaceReader.displayID(for: display)
    }

    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.reconcileScheduled = false
            self?.reconcile()
        }
    }

    private func reconcile(groupKey: GroupKey? = nil) {
        latestRecords = inventory.visibleEligibleWindows()
        observations?.sync(
            applications: NSWorkspace.shared.runningApplications,
            records: latestRecords
        )
        let currentSpaces = spaces.currentSpacesByDisplay()
        let activeKeys = store.groups.keys.filter { key in
            currentSpaces[key.displayID] == key.spaceID && (groupKey == nil || groupKey == key)
        }
        for key in activeKeys {
            let keys = latestRecords.filter { $0.groupKey == key }.map(\.key)
            _ = store.reconcile(key: key, eligibleFrontToBack: keys)
        }
        if let focused = inventory.focusedWindow(in: latestRecords), store.groups[focused.groupKey] != nil {
            _ = store.activate(focused.key, in: focused.groupKey)
        }
    }

    private func printMembers(_ group: WindowGroup, records: [WindowRecord]) {
        for (index, member) in group.members.enumerated() {
            let title = records.first { $0.key == member.key }?.title ?? "Unavailable"
            print("  \(index + 1). \(title) [\(member.key)]")
        }
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

@MainActor
private func run() throws {
    setbuf(stdout, nil)
    let options = Options.parse(CommandLine.arguments)
    let spaces = try SpaceReader()
    let identity = try AXWindowIdentity()
    if options.probe {
        let currentSpaces = spaces.currentSpacesByDisplay()
        guard !currentSpaces.isEmpty else {
            throw PrototypeError.privateAPI("SkyLight returned no current display/Space identities")
        }
        print("Read-only Space probe:")
        for (display, space) in currentSpaces.sorted(by: { $0.key < $1.key }) {
            print("  display=\(display) space=\(space)")
        }
        print("Exact AX↔CG window identity symbol: available")
        return
    }
    guard accessibilityIsTrusted(requestIfNeeded: options.requestAccessibility) else {
        throw PrototypeError.accessibilityPermission
    }
    let processLock = try SingletonProcessLock()
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let controller = DesktopGroupController(spaces: spaces, identity: identity)
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
