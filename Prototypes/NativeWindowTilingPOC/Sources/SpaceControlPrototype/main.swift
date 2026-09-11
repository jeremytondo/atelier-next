import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import SpaceControlCore

private enum PrototypeError: LocalizedError {
  case accessibilityPermission
  case alreadyRunning
  case hotKey(String)
  case privateAPI(String)

  var errorDescription: String? {
    switch self {
    case .accessibilityPermission:
      "Accessibility permission is required. Enable the terminal running this prototype in System Settings > Privacy & Security > Accessibility."
    case .alreadyRunning:
      "Another Space Control prototype is already running for this user"
    case .hotKey(let message), .privateAPI(let message):
      message
    }
  }
}

private struct Options {
  let probe: Bool
  let requestAccessibility: Bool

  static func parse(_ arguments: [String]) {
    if arguments.contains("--help") || arguments.contains("-h") {
      print(
        """
        Usage: space-control-prototype [--probe] [--request-accessibility]

          Option-1…9      Switch to ordinary Desktop 1…9 on the target display
          Option-0        Switch to ordinary Desktop 10
          Option-`        Create a native Desktop and leave Mission Control open
          Control-↑        Open Mission Control using the native macOS shortcut

          In Mission Control: ←/→ or h/l activate, Command-←/→ reorder, Delete remove
                              1…9/0 activate Desktop 1…10 and keep it open
                              Return enter the active Desktop

        The target display contains the focused window, falling back to the pointer.
        State and hotkeys last only while this process runs. Control-C exits.

          --probe                  Print topology/API availability and exit
          --request-accessibility  Ask macOS to show the Accessibility prompt
        """)
      exit(EXIT_SUCCESS)
    }
  }

  static func values(_ arguments: [String]) -> Options {
    parse(arguments)
    return Options(
      probe: arguments.contains("--probe"),
      requestAccessibility: arguments.contains("--request-accessibility")
    )
  }
}

private final class SingletonProcessLock {
  private let descriptor: Int32

  init() throws {
    let path = "/tmp/com.elevenideas.atelier.space-control.\(getuid()).lock"
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else {
      throw PrototypeError.privateAPI("Could not open the Space Control process lock")
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
  return AXIsProcessTrustedWithOptions(
    [
      "AXTrustedCheckOptionPrompt": true
    ] as CFDictionary)
}

private func copyAXAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
    return nil
  }
  return value
}

private final class SpaceRuntime {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
  private typealias GetSymbolicHotKeyValue =
    @convention(c) (
      UInt32,
      UnsafeMutablePointer<Int32>?,
      UnsafeMutablePointer<CGKeyCode>,
      UnsafeMutablePointer<UInt32>
    ) -> CGError
  private typealias IsSymbolicHotKeyEnabled = @convention(c) (UInt32) -> Bool
  private typealias SetSymbolicHotKeyEnabled = @convention(c) (UInt32, Bool) -> CGError

  private let handle: UnsafeMutableRawPointer
  private let connectionID: Int32
  private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
  private let getSymbolicHotKeyValue: GetSymbolicHotKeyValue
  private let isSymbolicHotKeyEnabled: IsSymbolicHotKeyEnabled
  private let setSymbolicHotKeyEnabled: SetSymbolicHotKeyEnabled
  private var temporarilyEnabled: Set<UInt32> = []
  private var restoreWorkItem: DispatchWorkItem?

  init() throws {
    let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
      throw PrototypeError.privateAPI("Could not open SkyLight.framework")
    }
    func symbol(_ primary: String, fallback: String? = nil) -> UnsafeMutableRawPointer? {
      dlsym(handle, primary) ?? fallback.flatMap { dlsym(handle, $0) }
    }
    guard let main = symbol("SLSMainConnectionID", fallback: "CGSMainConnectionID"),
      let copy = symbol("SLSCopyManagedDisplaySpaces", fallback: "CGSCopyManagedDisplaySpaces"),
      let get = symbol("CGSGetSymbolicHotKeyValue"),
      let isEnabled = symbol("CGSIsSymbolicHotKeyEnabled"),
      let setEnabled = symbol("CGSSetSymbolicHotKeyEnabled")
    else {
      dlclose(handle)
      throw PrototypeError.privateAPI("Required SkyLight Space/hotkey symbols are unavailable")
    }
    self.handle = handle
    let mainConnection = unsafeBitCast(main, to: MainConnection.self)
    self.connectionID = mainConnection()
    self.copyManagedDisplaySpaces = unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self)
    self.getSymbolicHotKeyValue = unsafeBitCast(get, to: GetSymbolicHotKeyValue.self)
    self.isSymbolicHotKeyEnabled = unsafeBitCast(isEnabled, to: IsSymbolicHotKeyEnabled.self)
    self.setSymbolicHotKeyEnabled = unsafeBitCast(setEnabled, to: SetSymbolicHotKeyEnabled.self)
  }

  deinit {
    restoreTemporarilyEnabledHotKeys()
    dlclose(handle)
  }

  func snapshot() -> [DisplaySpaceSnapshot] {
    guard let value = copyManagedDisplaySpaces(connectionID)?.takeRetainedValue(),
      let raw = value as? [[String: Any]]
    else {
      return []
    }
    return SpaceTopology.decode(raw)
  }

  /// Posts one of macOS's own symbolic actions. Disabled actions are enabled
  /// only in the live WindowServer and restored after the event is matched;
  /// no preference is written.
  func postSymbolicHotKey(_ id: UInt32) -> Bool {
    guard let (keyCode, flags) = symbolicHotKeyValue(id) else { return false }

    if !isSymbolicHotKeyEnabled(id) {
      guard setSymbolicHotKeyEnabled(id, true) == .success else { return false }
      temporarilyEnabled.insert(id)
      scheduleRestore()
    }

    guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    else {
      return false
    }
    keyDown.flags = CGEventFlags(rawValue: UInt64(flags))
    keyUp.flags = []
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
  }

  func symbolicHotKeyValue(_ id: UInt32) -> (CGKeyCode, UInt32)? {
    var keyCode: CGKeyCode = 0
    var flags: UInt32 = 0
    guard getSymbolicHotKeyValue(id, nil, &keyCode, &flags) == .success else {
      return nil
    }
    return (keyCode, flags)
  }

  func restoreTemporarilyEnabledHotKeys() {
    restoreWorkItem?.cancel()
    restoreWorkItem = nil
    for id in temporarilyEnabled {
      _ = setSymbolicHotKeyEnabled(id, false)
    }
    temporarilyEnabled.removeAll()
  }

  private func scheduleRestore() {
    restoreWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.restoreTemporarilyEnabledHotKeys()
    }
    restoreWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
  }
}

private struct TargetDisplay {
  let displayID: CGDirectDisplayID
  let topologyIdentifier: String
  let source: String
}

private final class TargetDisplayResolver {
  func resolve(
    in topology: [DisplaySpaceSnapshot],
    preferPointer: Bool = false
  ) -> TargetDisplay? {
    if preferPointer, let target = pointerDisplay(in: topology) {
      return target
    }
    if let displayID = focusedWindowDisplayID(),
      let identifier = topologyIdentifier(for: displayID, in: topology)
    {
      return TargetDisplay(
        displayID: displayID,
        topologyIdentifier: identifier,
        source: "focused window"
      )
    }
    return pointerDisplay(in: topology)
  }

  private func pointerDisplay(in topology: [DisplaySpaceSnapshot]) -> TargetDisplay? {
    guard let point = CGEvent(source: nil)?.location,
      let displayID = displayID(containing: point),
      let identifier = topologyIdentifier(for: displayID, in: topology)
    else {
      return nil
    }
    return TargetDisplay(
      displayID: displayID,
      topologyIdentifier: identifier,
      source: "pointer"
    )
  }

  private func focusedWindowDisplayID() -> CGDirectDisplayID? {
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    guard let value = copyAXAttribute(appElement, kAXFocusedWindowAttribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    let window = unsafeDowncast(value, to: AXUIElement.self)
    guard let positionValue = copyAXAttribute(window, kAXPositionAttribute),
      let sizeValue = copyAXAttribute(window, kAXSizeAttribute),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
      AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
    else {
      return nil
    }
    return displayID(containing: CGRect(origin: position, size: size))
  }

  private func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
    var display: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else {
      return nil
    }
    return display
  }

  private func displayID(containing rect: CGRect) -> CGDirectDisplayID? {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetDisplaysWithRect(rect, UInt32(displays.count), &displays, &count) == .success,
      count > 0
    else {
      return nil
    }
    return displays.prefix(Int(count)).max {
      CGDisplayBounds($0).intersection(rect).area < CGDisplayBounds($1).intersection(rect).area
    }
  }

  private func topologyIdentifier(
    for displayID: CGDirectDisplayID,
    in topology: [DisplaySpaceSnapshot]
  ) -> String? {
    if displayID == CGMainDisplayID(), topology.contains(where: { $0.identifier == "Main" }) {
      return "Main"
    }
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
      let string = CFUUIDCreateString(nil, uuid)
    else {
      return nil
    }
    let identifier = (string as String).uppercased()
    return topology.first { $0.identifier.uppercased() == identifier }?.identifier
  }
}

extension CGRect {
  fileprivate var area: CGFloat { isNull ? 0 : width * height }
}

private enum HotKeyCommand: Sendable {
  case desktop(Int)
  case activateDesktop(Int)
  case create
  case activate(Int)
  case reorder(Int)
  case deleteActive
  case enterActive
}

private struct MissionControlError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private final class HotKeyController {
  private static let signature: OSType = 0x4154_5343  // ATSC
  private static let contextualIDs: Set<UInt32> = [
    101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
    111, 112, 113, 114, 115, 116, 117, 118, 119, 120,
  ]
  private var references: [UInt32: EventHotKeyRef] = [:]
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
      spaceControlHotKeyHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &handler
    )
    guard status == noErr else {
      throw PrototypeError.hotKey("Could not install hotkey handler (\(status))")
    }

    do {
      let digits: [(Int, Int)] = [
        (kVK_ANSI_1, 1), (kVK_ANSI_2, 2), (kVK_ANSI_3, 3), (kVK_ANSI_4, 4),
        (kVK_ANSI_5, 5), (kVK_ANSI_6, 6), (kVK_ANSI_7, 7), (kVK_ANSI_8, 8),
        (kVK_ANSI_9, 9), (kVK_ANSI_0, 10),
      ]
      for (keyCode, number) in digits {
        try register(
          id: UInt32(10 + number),
          keyCode: UInt32(keyCode),
          modifiers: UInt32(optionKey)
        )
      }
      try register(
        id: 1,
        keyCode: UInt32(kVK_ANSI_Grave),
        modifiers: UInt32(optionKey)
      )
    } catch {
      unregisterAll()
      throw error
    }
  }

  deinit {
    unregisterAll()
  }

  func setMissionControlBindingsEnabled(_ enabled: Bool) throws {
    if enabled {
      guard references[101] == nil else { return }
      do {
        try register(
          id: 101,
          keyCode: UInt32(kVK_LeftArrow),
          modifiers: 0,
          options: UInt32(kEventHotKeyExclusive)
        )
        try register(
          id: 102,
          keyCode: UInt32(kVK_RightArrow),
          modifiers: 0,
          options: UInt32(kEventHotKeyExclusive)
        )
        try register(
          id: 103,
          keyCode: UInt32(kVK_LeftArrow),
          modifiers: UInt32(cmdKey),
          options: UInt32(kEventHotKeyExclusive)
        )
        try register(
          id: 104,
          keyCode: UInt32(kVK_RightArrow),
          modifiers: UInt32(cmdKey),
          options: UInt32(kEventHotKeyExclusive)
        )
        try register(
          id: 105,
          keyCode: UInt32(kVK_Delete),
          modifiers: 0,
          options: UInt32(kEventHotKeyExclusive)
        )
        try register(
          id: 106,
          keyCode: UInt32(kVK_ForwardDelete),
          modifiers: 0,
          options: UInt32(kEventHotKeyExclusive)
        )
        try register(
          id: 107,
          keyCode: UInt32(kVK_Return),
          modifiers: 0,
          options: UInt32(kEventHotKeyExclusive)
        )
        try register(
          id: 108,
          keyCode: UInt32(kVK_ANSI_KeypadEnter),
          modifiers: 0,
          options: UInt32(kEventHotKeyExclusive)
        )
        try register(
          id: 109,
          keyCode: UInt32(kVK_ANSI_H),
          modifiers: 0,
          options: UInt32(kEventHotKeyExclusive)
        )
        try register(
          id: 110,
          keyCode: UInt32(kVK_ANSI_L),
          modifiers: 0,
          options: UInt32(kEventHotKeyExclusive)
        )
        let digits: [(Int, Int)] = [
          (kVK_ANSI_1, 1), (kVK_ANSI_2, 2), (kVK_ANSI_3, 3), (kVK_ANSI_4, 4),
          (kVK_ANSI_5, 5), (kVK_ANSI_6, 6), (kVK_ANSI_7, 7), (kVK_ANSI_8, 8),
          (kVK_ANSI_9, 9), (kVK_ANSI_0, 10),
        ]
        for (keyCode, number) in digits {
          try register(
            id: UInt32(110 + number),
            keyCode: UInt32(keyCode),
            modifiers: 0,
            options: UInt32(kEventHotKeyExclusive)
          )
        }
      } catch {
        unregister(ids: Self.contextualIDs)
        throw error
      }
    } else {
      unregister(ids: Self.contextualIDs)
    }
  }

  private func unregisterAll() {
    for reference in references.values {
      _ = UnregisterEventHotKey(reference)
    }
    references.removeAll()
    if let handler {
      RemoveEventHandler(handler)
      self.handler = nil
    }
  }

  func receive(id: UInt32) {
    switch id {
    case 1: onCommand(.create)
    case 11...20: onCommand(.desktop(Int(id - 10)))
    case 101: onCommand(.activate(-1))
    case 102: onCommand(.activate(1))
    case 103: onCommand(.reorder(-1))
    case 104: onCommand(.reorder(1))
    case 105, 106: onCommand(.deleteActive)
    case 107, 108: onCommand(.enterActive)
    case 109: onCommand(.activate(-1))
    case 110: onCommand(.activate(1))
    case 111...120: onCommand(.activateDesktop(Int(id - 110)))
    default: break
    }
  }

  private func register(
    id: UInt32,
    keyCode: UInt32,
    modifiers: UInt32,
    options: UInt32 = 0
  ) throws {
    guard references[id] == nil else { return }
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCode,
      modifiers,
      EventHotKeyID(signature: Self.signature, id: id),
      GetApplicationEventTarget(),
      options,
      &reference
    )
    guard status == noErr, let reference else {
      throw PrototypeError.hotKey(
        "Could not register Space Control hotkey id \(id) (\(status)); another app may own it"
      )
    }
    references[id] = reference
  }

  private func unregister(ids: Set<UInt32>) {
    for id in ids {
      guard let reference = references.removeValue(forKey: id) else { continue }
      _ = UnregisterEventHotKey(reference)
    }
  }
}

private func spaceControlHotKeyHandler(
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
  guard status == noErr, hotKeyID.signature == 0x4154_5343 else {
    return OSStatus(eventNotHandledErr)
  }
  Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue().receive(id: hotKeyID.id)
  return noErr
}

private final class MissionControlAccessibility {
  private static let missionControlAction: UInt32 = 32
  private static let previousSpaceAction: UInt32 = 79
  private static let nextSpaceAction: UInt32 = 81
  private static let firstDesktopAction: UInt32 = 118
  private static let maximumSymbolicDesktop = 16
  private static let presentationSettleTime: TimeInterval = 0.35
  private static let minimumExpandedThumbnailHeight: CGFloat = 48
  private static let thumbnailSettleTime: TimeInterval = 0.25
  private let runtime: SpaceRuntime
  private var pointerPositionBeforeKeyboardNavigation: CGPoint?
  private var lastSyntheticPointerPosition: CGPoint?

  init(runtime: SpaceRuntime) {
    self.runtime = runtime
  }

  func isVisible() -> Bool {
    missionControlRoot() != nil
  }

  func resetKeyboardNavigation() {
    defer {
      pointerPositionBeforeKeyboardNavigation = nil
      lastSyntheticPointerPosition = nil
    }
    guard let originalPosition = pointerPositionBeforeKeyboardNavigation,
      let syntheticPosition = lastSyntheticPointerPosition,
      let currentPosition = currentPointerPosition(),
      hypot(
        currentPosition.x - syntheticPosition.x,
        currentPosition.y - syntheticPosition.y
      ) <= 6
    else {
      return
    }
    _ = postPointerMove(to: originalPosition)
  }

  func beginKeyboardNavigation(
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard
      let display = topology.first(where: {
        $0.identifier == target.topologyIdentifier
      }),
      let currentIndex = display.regularDesktops.firstIndex(where: {
        $0.id == display.currentSpaceID
      })
    else {
      return .failure(MissionControlError(message: "Could not resolve the current Desktop"))
    }
    // Dock exposes its AX root before the entrance animation finishes. Hovering
    // the top edge during that animation is ignored, so wait before requesting expansion.
    RunLoop.current.run(
      until: Date().addingTimeInterval(Self.presentationSettleTime)
    )
    guard ensureExpandedSpacesBar(on: target, topology: topology) else {
      return .failure(
        MissionControlError(message: "The native Spaces bar did not expand"))
    }
    return .success(currentIndex + 1)
  }

  func createDesktop(
    on target: TargetDisplay,
    before: [DisplaySpaceSnapshot]
  ) -> Result<UInt64, MissionControlError> {
    if !isVisible() {
      guard runtime.postSymbolicHotKey(Self.missionControlAction) else {
        return .failure(
          MissionControlError(message: "Could not invoke macOS's Mission Control action"))
      }
      guard waitForMissionControlRoot(timeout: 3) != nil else {
        return .failure(
          MissionControlError(
            message: "Dock did not expose the Mission Control accessibility hierarchy"))
      }

      // Mission Control's AX hierarchy appears before its entrance animation
      // is visually complete. Let its presentation land before adding.
      RunLoop.current.run(
        until: Date().addingTimeInterval(Self.presentationSettleTime)
      )
    }

    guard ensureExpandedSpacesBar(on: target, topology: before) else {
      return .failure(
        MissionControlError(message: "Could not expand the native Spaces bar before creation"))
    }

    guard let settledRoot = waitForMissionControlRoot(timeout: 1),
      let display = missionControlDisplay(in: settledRoot, displayID: target.displayID),
      let addButton = firstDescendant(of: display, identifier: "mc.spaces.add")
    else {
      return .failure(
        MissionControlError(
          message: "Could not find the native Add Desktop button for the target display"))
    }
    guard AXUIElementPerformAction(addButton, kAXPressAction as CFString) == .success else {
      return .failure(
        MissionControlError(message: "The native Add Desktop button rejected AXPress"))
    }

    guard
      let (added, after) = waitForAddedDesktop(
        displayIdentifier: target.topologyIdentifier,
        before: before,
        timeout: 3
      )
    else {
      return .failure(
        MissionControlError(message: "macOS did not report exactly one new ordinary Desktop"))
    }

    guard
      let fullIndex = SpaceTopology.fullIndex(
        of: added.id,
        on: target.topologyIdentifier,
        displays: after
      ),
      let expectedCount = after.first(where: {
        $0.identifier == target.topologyIdentifier
      })?.spaces.count,
      waitForExpandedSpaceButton(
        displayID: target.displayID,
        index: fullIndex,
        expectedCount: expectedCount,
        timeout: 3
      ) != nil
    else {
      return .failure(
        MissionControlError(
          message: "Created Desktop \(added.id), but its Mission Control thumbnail did not settle"
        ))
    }

    guard
      let createdNumber = after.first(where: {
        $0.identifier == target.topologyIdentifier
      })?.regularDesktops.firstIndex(where: { $0.id == added.id }).map({ $0 + 1 })
    else {
      return .failure(
        MissionControlError(message: "Could not resolve the created Desktop number"))
    }
    switch activateDesktop(number: createdNumber, on: target, topology: after) {
    case .success:
      break
    case .failure(let error):
      return .failure(
        MissionControlError(
          message: "Created Desktop \(createdNumber), but could not activate it: \(error.message)"))
    }
    return .success(added.id)
  }

  func selectDesktop(
    _ desktop: ManagedSpaceSnapshot,
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Void, MissionControlError> {
    guard isVisible() else {
      return .failure(MissionControlError(message: "Mission Control is no longer open"))
    }
    guard
      let fullIndex = SpaceTopology.fullIndex(
        of: desktop.id,
        on: target.topologyIdentifier,
        displays: topology
      ),
      let expectedCount = topology.first(where: {
        $0.identifier == target.topologyIdentifier
      })?.spaces.count,
      let button = waitForStableSpaceButton(
        displayID: target.displayID,
        index: fullIndex,
        expectedCount: expectedCount,
        timeout: 2
      )
    else {
      return .failure(
        MissionControlError(
          message: "Could not resolve Desktop \(desktop.id) in Mission Control"))
    }

    guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
      return .failure(
        MissionControlError(message: "Desktop \(desktop.id) rejected Mission Control selection"))
    }
    guard waitForCurrentSpace(desktop.id, on: target.topologyIdentifier, timeout: 3) else {
      return .failure(
        MissionControlError(message: "Could not verify the switch to Desktop \(desktop.id)"))
    }
    guard waitForMissionControlToClose(timeout: 3) || closeMissionControl(timeout: 2) else {
      return .failure(
        MissionControlError(
          message: "Switched to Desktop \(desktop.id), but Mission Control did not close cleanly"))
    }
    return .success(())
  }

  func activateAdjacentDesktop(
    offset: Int,
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard isVisible() else {
      return .failure(MissionControlError(message: "Mission Control is no longer open"))
    }
    guard let (display, currentIndex) = activeDesktop(on: target, topology: topology) else {
      return .failure(MissionControlError(message: "No ordinary Desktop is currently active"))
    }
    let desktops = display.regularDesktops
    let nextIndex = min(max(currentIndex + offset, 0), desktops.count - 1)
    guard nextIndex != currentIndex else { return .success(currentIndex + 1) }

    let current = desktops[currentIndex]
    let destination = desktops[nextIndex]
    guard let currentFullIndex = display.spaces.firstIndex(where: { $0.id == current.id }),
      let destinationFullIndex = display.spaces.firstIndex(where: { $0.id == destination.id })
    else {
      return .failure(
        MissionControlError(message: "Could not resolve the adjacent Desktop route"))
    }

    let action = offset < 0 ? Self.previousSpaceAction : Self.nextSpaceAction
    let step = offset < 0 ? -1 : 1
    for fullIndex in stride(
      from: currentFullIndex + step,
      through: destinationFullIndex,
      by: step
    ) {
      let expectedSpace = display.spaces[fullIndex]
      guard runtime.postSymbolicHotKey(action),
        waitForCurrentSpace(
          expectedSpace.id,
          on: target.topologyIdentifier,
          timeout: 3
        ),
        waitForMissionControlRoot(timeout: 2) != nil
      else {
        return .failure(
          MissionControlError(
            message:
              "macOS did not keep Mission Control open while activating Desktop \(nextIndex + 1)"
          ))
      }
    }

    let updatedTopology = runtime.snapshot()
    guard
      updatedTopology.first(where: {
        $0.identifier == target.topologyIdentifier
      })?.currentSpaceID == destination.id,
      ensureExpandedSpacesBar(on: target, topology: updatedTopology)
    else {
      return .failure(
        MissionControlError(message: "The active Desktop thumbnail did not remain expanded"))
    }
    return .success(nextIndex + 1)
  }

  func activateDesktop(
    number: Int,
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard isVisible() else {
      return .failure(MissionControlError(message: "Mission Control is no longer open"))
    }
    guard
      let destination = SpaceTopology.desktop(
        number: number,
        on: target.topologyIdentifier,
        displays: topology
      )
    else {
      return .failure(MissionControlError(message: "Desktop \(number) does not exist"))
    }
    guard
      topology.first(where: { $0.identifier == target.topologyIdentifier })?.currentSpaceID
        != destination.id
    else {
      return .success(number)
    }
    guard
      let globalNumber = SpaceTopology.globalDesktopNumber(
        for: destination.id,
        displays: topology
      ), globalNumber <= Self.maximumSymbolicDesktop
    else {
      return .failure(
        MissionControlError(message: "Desktop \(number) has no native symbolic shortcut route"))
    }

    let action = Self.firstDesktopAction + UInt32(globalNumber - 1)
    guard runtime.postSymbolicHotKey(action),
      waitForCurrentSpace(destination.id, on: target.topologyIdentifier, timeout: 3),
      waitForMissionControlRoot(timeout: 2) != nil
    else {
      return .failure(
        MissionControlError(
          message: "macOS did not keep Mission Control open while activating Desktop \(number)"))
    }

    let updatedTopology = runtime.snapshot()
    guard ensureExpandedSpacesBar(on: target, topology: updatedTopology) else {
      return .failure(
        MissionControlError(message: "The active Desktop thumbnail did not remain expanded"))
    }
    return .success(number)
  }

  func enterActiveDesktop(
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard isVisible() else {
      return .failure(MissionControlError(message: "Mission Control is no longer open"))
    }
    guard let (display, activeIndex) = activeDesktop(on: target, topology: topology) else {
      return .failure(MissionControlError(message: "No ordinary Desktop is currently active"))
    }
    let active = display.regularDesktops[activeIndex]
    guard let fullIndex = display.spaces.firstIndex(where: { $0.id == active.id }),
      let button = waitForExpandedSpaceButton(
        displayID: target.displayID,
        index: fullIndex,
        expectedCount: display.spaces.count,
        timeout: 2
      )
    else {
      return .failure(
        MissionControlError(message: "Could not resolve the active Desktop thumbnail"))
    }
    guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
      return .failure(
        MissionControlError(message: "The active Desktop rejected selection"))
    }
    guard waitForMissionControlToClose(timeout: 3) || closeMissionControl(timeout: 2) else {
      return .failure(
        MissionControlError(message: "Mission Control did not close after entering the Desktop"))
    }
    guard currentSpaceID(on: target.topologyIdentifier) == active.id else {
      return .failure(
        MissionControlError(message: "The active Desktop changed while Mission Control closed"))
    }
    return .success(activeIndex + 1)
  }

  func reorderActiveDesktop(
    offset: Int,
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard isVisible() else {
      return .failure(MissionControlError(message: "Mission Control is no longer open"))
    }
    guard let (display, sourceIndex) = activeDesktop(on: target, topology: topology) else {
      return .failure(MissionControlError(message: "No ordinary Desktop is currently active"))
    }
    let desktops = display.regularDesktops
    let destinationIndex = sourceIndex + offset
    guard desktops.indices.contains(destinationIndex) else {
      return .success(sourceIndex + 1)
    }

    let active = desktops[sourceIndex]
    let destination = desktops[destinationIndex]
    guard let sourceFullIndex = display.spaces.firstIndex(where: { $0.id == active.id }),
      let destinationFullIndex = display.spaces.firstIndex(where: { $0.id == destination.id }),
      let sourceButton = spaceButton(
        displayID: target.displayID,
        index: sourceFullIndex,
        expectedCount: display.spaces.count
      ),
      let destinationButton = spaceButton(
        displayID: target.displayID,
        index: destinationFullIndex,
        expectedCount: display.spaces.count
      ),
      let sourceFrame = frame(of: sourceButton),
      let destinationFrame = frame(of: destinationButton)
    else {
      return .failure(
        MissionControlError(message: "Could not resolve the active Desktop thumbnails"))
    }

    let destinationPoint = CGPoint(
      x: offset < 0 ? destinationFrame.minX + 4 : destinationFrame.maxX - 4,
      y: destinationFrame.midY
    )
    guard drag(from: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY), to: destinationPoint) else {
      return .failure(MissionControlError(message: "Could not synthesize the Desktop drag"))
    }

    guard
      waitUntil(
        timeout: 3,
        condition: {
          let snapshot = self.runtime.snapshot()
          guard
            let updatedDisplay = snapshot.first(where: {
              $0.identifier == target.topologyIdentifier
            }),
            updatedDisplay.regularDesktops.firstIndex(where: { $0.id == active.id })
              == destinationIndex
          else {
            return false
          }
          return true
        })
    else {
      return .failure(
        MissionControlError(message: "macOS did not confirm the Desktop reorder"))
    }

    guard ensureExpandedSpacesBar(on: target, topology: runtime.snapshot()) else {
      return .failure(
        MissionControlError(message: "The reordered Desktop thumbnail did not remain expanded"))
    }
    return .success(destinationIndex + 1)
  }

  func deleteActiveDesktop(
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Result<Int, MissionControlError> {
    guard isVisible() else {
      return .failure(MissionControlError(message: "Mission Control is no longer open"))
    }
    guard let (display, activeIndex) = activeDesktop(on: target, topology: topology) else {
      return .failure(MissionControlError(message: "No ordinary Desktop is currently active"))
    }
    let desktops = display.regularDesktops
    guard desktops.count > 1 else {
      return .failure(MissionControlError(message: "The final Desktop cannot be deleted"))
    }
    let desktopToDelete = desktops[activeIndex]
    let neighborOffset = activeIndex < desktops.count - 1 ? 1 : -1
    let neighborIndex = activeIndex + neighborOffset
    let neighbor = desktops[neighborIndex]

    switch activateAdjacentDesktop(offset: neighborOffset, on: target, topology: topology) {
    case .failure(let error):
      return .failure(
        MissionControlError(
          message: "Could not leave the active Desktop before deletion: \(error.message)"))
    case .success:
      break
    }

    guard
      let afterActivation = runtime.snapshot().first(where: {
        $0.identifier == target.topologyIdentifier
      }), afterActivation.currentSpaceID == neighbor.id,
      let fullIndex = afterActivation.spaces.firstIndex(where: { $0.id == desktopToDelete.id }),
      let button = waitForStableSpaceButton(
        displayID: target.displayID,
        index: fullIndex,
        expectedCount: afterActivation.spaces.count,
        timeout: 2
      )
    else {
      return .failure(
        MissionControlError(message: "Could not resolve the former active Desktop thumbnail"))
    }
    guard AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString) == .success else {
      return .failure(
        MissionControlError(message: "Desktop \(activeIndex + 1) rejected deletion"))
    }

    var updatedDisplay: DisplaySpaceSnapshot?
    guard
      waitUntil(
        timeout: 3,
        condition: {
          guard
            let candidate = self.runtime.snapshot().first(where: {
              $0.identifier == target.topologyIdentifier
            }), !candidate.spaces.contains(where: { $0.id == desktopToDelete.id })
          else {
            return false
          }
          updatedDisplay = candidate
          return true
        }), let updatedDisplay
    else {
      return .failure(MissionControlError(message: "macOS did not confirm Desktop deletion"))
    }

    guard updatedDisplay.currentSpaceID == neighbor.id else {
      return .failure(
        MissionControlError(message: "The neighboring Desktop did not remain active"))
    }
    guard ensureExpandedSpacesBar(on: target, topology: [updatedDisplay]) else {
      return .failure(
        MissionControlError(message: "The neighboring Desktop thumbnail did not remain expanded"))
    }
    return .success(activeIndex + 1)
  }

  private func activeDesktop(
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> (DisplaySpaceSnapshot, Int)? {
    guard
      let display = topology.first(where: {
        $0.identifier == target.topologyIdentifier
      }), !display.regularDesktops.isEmpty
    else {
      return nil
    }
    guard
      let index = display.regularDesktops.firstIndex(where: {
        $0.id == display.currentSpaceID
      })
    else {
      return nil
    }
    return (display, index)
  }

  private func spaceButton(
    displayID: CGDirectDisplayID,
    index: Int,
    expectedCount: Int
  ) -> AXUIElement? {
    guard let root = missionControlRoot(),
      let display = missionControlDisplay(in: root, displayID: displayID),
      let list = firstDescendant(of: display, identifier: "mc.spaces.list"),
      let children = copyAXAttribute(list, kAXChildrenAttribute) as? [AXUIElement],
      children.count == expectedCount,
      children.indices.contains(index)
    else {
      return nil
    }
    return children[index]
  }

  private func frame(of element: AXUIElement) -> CGRect? {
    guard let positionValue = copyAXAttribute(element, kAXPositionAttribute),
      let sizeValue = copyAXAttribute(element, kAXSizeAttribute),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
      AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
    else {
      return nil
    }
    return CGRect(origin: position, size: size)
  }

  private func ensureExpandedSpacesBar(
    on target: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) -> Bool {
    guard
      let display = topology.first(where: {
        $0.identifier == target.topologyIdentifier
      }),
      let currentFullIndex = display.spaces.firstIndex(where: {
        $0.id == display.currentSpaceID
      }),
      expandSpacesBar(on: target.displayID)
    else {
      return false
    }
    return waitForExpandedSpaceButton(
      displayID: target.displayID,
      index: currentFullIndex,
      expectedCount: display.spaces.count,
      timeout: 2
    ) != nil
  }

  private func expandSpacesBar(on displayID: CGDirectDisplayID) -> Bool {
    let bounds = CGDisplayBounds(displayID)
    guard !bounds.isNull, bounds.width > 2, bounds.height > 2 else { return false }
    let currentX = currentPointerPosition()?.x ?? bounds.midX
    let point = CGPoint(
      x: min(max(currentX, bounds.minX + 1), bounds.maxX - 1),
      y: bounds.minY + 1
    )
    return movePointer(to: point)
  }

  private func movePointer(to point: CGPoint) -> Bool {
    if pointerPositionBeforeKeyboardNavigation == nil {
      pointerPositionBeforeKeyboardNavigation = currentPointerPosition()
    }
    guard postPointerMove(to: point) else { return false }
    lastSyntheticPointerPosition = point
    return true
  }

  private func postPointerMove(to point: CGPoint) -> Bool {
    guard CGWarpMouseCursorPosition(point) == .success,
      let event = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
      )
    else {
      return false
    }
    event.post(tap: .cghidEventTap)
    return true
  }

  private func currentPointerPosition() -> CGPoint? {
    CGEvent(source: nil)?.location
  }

  private func drag(from sourcePoint: CGPoint, to destinationPoint: CGPoint) -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState),
      let move = CGEvent(
        mouseEventSource: source,
        mouseType: .mouseMoved,
        mouseCursorPosition: sourcePoint,
        mouseButton: .left
      ),
      let down = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseDown,
        mouseCursorPosition: sourcePoint,
        mouseButton: .left
      ),
      let up = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseUp,
        mouseCursorPosition: destinationPoint,
        mouseButton: .left
      )
    else {
      return false
    }

    move.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    down.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.12))

    let steps = 10
    for step in 1...steps {
      let progress = CGFloat(step) / CGFloat(steps)
      let point = CGPoint(
        x: sourcePoint.x + (destinationPoint.x - sourcePoint.x) * progress,
        y: sourcePoint.y + (destinationPoint.y - sourcePoint.y) * progress
      )
      guard
        let dragged = CGEvent(
          mouseEventSource: source,
          mouseType: .leftMouseDragged,
          mouseCursorPosition: point,
          mouseButton: .left
        )
      else {
        up.post(tap: .cghidEventTap)
        return false
      }
      dragged.post(tap: .cghidEventTap)
      RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    up.post(tap: .cghidEventTap)
    return true
  }

  private func waitForAddedDesktop(
    displayIdentifier: String,
    before: [DisplaySpaceSnapshot],
    timeout: TimeInterval
  ) -> (ManagedSpaceSnapshot, [DisplaySpaceSnapshot])? {
    var result: (ManagedSpaceSnapshot, [DisplaySpaceSnapshot])?
    _ = waitUntil(timeout: timeout) {
      let after = self.runtime.snapshot()
      guard
        let added = SpaceTopology.addedDesktop(
          on: displayIdentifier,
          before: before,
          after: after
        )
      else {
        return false
      }
      result = (added, after)
      return true
    }
    return result
  }

  private func waitForMissionControlRoot(timeout: TimeInterval) -> AXUIElement? {
    var result: AXUIElement?
    _ = waitUntil(timeout: timeout) {
      result = self.missionControlRoot()
      return result != nil
    }
    return result
  }

  private func missionControlRoot() -> AXUIElement? {
    guard
      let dock = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).first
    else {
      return nil
    }
    let root = AXUIElementCreateApplication(dock.processIdentifier)
    return firstDescendant(of: root, identifier: "mc", maximumDepth: 3)
  }

  private func waitForStableSpaceButton(
    displayID: CGDirectDisplayID,
    index: Int,
    expectedCount: Int,
    timeout: TimeInterval
  ) -> AXUIElement? {
    var candidate: AXUIElement?
    var readySince: Date?
    _ = waitUntil(timeout: timeout) {
      guard
        let button = self.spaceButton(
          displayID: displayID,
          index: index,
          expectedCount: expectedCount
        )
      else {
        candidate = nil
        readySince = nil
        return false
      }
      candidate = button
      if let readySince {
        return Date().timeIntervalSince(readySince) >= Self.thumbnailSettleTime
      }
      readySince = Date()
      return false
    }
    return candidate
  }

  private func waitForExpandedSpaceButton(
    displayID: CGDirectDisplayID,
    index: Int,
    expectedCount: Int,
    timeout: TimeInterval
  ) -> AXUIElement? {
    var candidate: AXUIElement?
    var stableFrame: CGRect?
    var stableSince: Date?
    let completed = waitUntil(timeout: timeout) {
      guard
        let button = self.spaceButton(
          displayID: displayID,
          index: index,
          expectedCount: expectedCount
        ),
        let frame = self.frame(of: button),
        frame.height >= Self.minimumExpandedThumbnailHeight
      else {
        candidate = nil
        stableFrame = nil
        stableSince = nil
        return false
      }
      candidate = button
      if let previousFrame = stableFrame,
        abs(previousFrame.minX - frame.minX) <= 1,
        abs(previousFrame.minY - frame.minY) <= 1,
        abs(previousFrame.width - frame.width) <= 1,
        abs(previousFrame.height - frame.height) <= 1
      {
        if let stableSince {
          return Date().timeIntervalSince(stableSince) >= Self.thumbnailSettleTime
        }
      } else {
        stableFrame = frame
        stableSince = Date()
      }
      return false
    }
    return completed ? candidate : nil
  }

  private func missionControlDisplay(
    in root: AXUIElement,
    displayID: CGDirectDisplayID
  ) -> AXUIElement? {
    descendants(of: root, maximumDepth: 4).first { element in
      guard attributeString(element, "AXIdentifier") == "mc.display",
        let value = copyAXAttribute(element, "AXDisplayID") as? NSNumber
      else {
        return false
      }
      return value.uint32Value == displayID
    }
  }

  private func firstDescendant(
    of root: AXUIElement,
    identifier: String,
    maximumDepth: Int = 8
  ) -> AXUIElement? {
    descendants(of: root, maximumDepth: maximumDepth).first {
      attributeString($0, "AXIdentifier") == identifier
    }
  }

  private func descendants(of root: AXUIElement, maximumDepth: Int) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var cursor = 0
    while cursor < queue.count, result.count < 2_000 {
      let (element, depth) = queue[cursor]
      cursor += 1
      result.append(element)
      guard depth < maximumDepth,
        let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
      else {
        continue
      }
      queue.append(contentsOf: children.map { ($0, depth + 1) })
    }
    return result
  }

  private func attributeString(_ element: AXUIElement, _ attribute: String) -> String? {
    copyAXAttribute(element, attribute) as? String
  }

  private func currentSpaceID(on displayIdentifier: String) -> UInt64? {
    runtime.snapshot().first {
      $0.identifier == displayIdentifier
    }?.currentSpaceID
  }

  private func waitForCurrentSpace(
    _ spaceID: UInt64,
    on displayIdentifier: String,
    timeout: TimeInterval
  ) -> Bool {
    waitUntil(timeout: timeout) {
      self.currentSpaceID(on: displayIdentifier) == spaceID
    }
  }

  private func closeMissionControl(timeout: TimeInterval) -> Bool {
    guard waitForMissionControlRoot(timeout: 0.1) != nil else { return true }
    guard runtime.postSymbolicHotKey(Self.missionControlAction) else { return false }
    return waitForMissionControlToClose(timeout: timeout)
  }

  private func waitForMissionControlToClose(timeout: TimeInterval) -> Bool {
    var absentSince: Date?
    return waitUntil(timeout: timeout) {
      if self.waitForMissionControlRoot(timeout: 0.05) != nil {
        absentSince = nil
        return false
      }
      if let absentAt = absentSince {
        return Date().timeIntervalSince(absentAt) >= 0.2
      }
      absentSince = Date()
      return false
    }
  }

  private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return condition()
  }
}

@MainActor
private final class SpaceControlController {
  private static let firstDesktopAction: UInt32 = 118
  private static let maximumSymbolicDesktop = 16
  private let runtime: SpaceRuntime
  private let resolver = TargetDisplayResolver()
  private lazy var missionControl = MissionControlAccessibility(runtime: runtime)
  private var hotKeys: HotKeyController?
  private var missionControlMonitor: Timer?
  private var missionControlBindingsEnabled = false
  private var missionControlNavigationPrepared = false
  private var missionControlNavigationPreparing = false
  private var commandInFlight = false
  private var lastDeleteAt = Date.distantPast

  init(runtime: SpaceRuntime) {
    self.runtime = runtime
  }

  func start() throws {
    hotKeys = try HotKeyController { [weak self] command in
      Task { @MainActor in self?.handle(command) }
    }
    let monitor = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.synchronizeMissionControlBindings() }
    }
    RunLoop.main.add(monitor, forMode: .common)
    missionControlMonitor = monitor
    print("Space Control prototype is running:")
    print("  Option-1…9 / Option-0  switch to Desktop 1…10")
    print("  Option-`                 create a Desktop and leave Mission Control open")
    print("  Control-↑                open Mission Control using the native macOS shortcut")
    print("  Mission Control: ←/→ or h/l activate, Command-←/→ reorder, Delete remove")
    print("                   1…9/0 activate Desktop 1…10 and keep Mission Control open")
    print("                   Return enter the active Desktop")
    print("Control-C exits. System Settings will not be modified.")
  }

  private func synchronizeMissionControlBindings() {
    // Expanding the bar, switching Spaces, reordering, and deletion can rebuild
    // Dock's AX tree. Ignore those transient samples so the hotkeys stay registered.
    guard !missionControlNavigationPreparing, !commandInFlight else { return }

    let shouldEnable = missionControl.isVisible()
    if shouldEnable != missionControlBindingsEnabled {
      missionControlBindingsEnabled = shouldEnable
      do {
        try hotKeys?.setMissionControlBindingsEnabled(shouldEnable)
        if shouldEnable {
          print("Mission Control keyboard controls enabled")
        } else {
          missionControlNavigationPrepared = false
          missionControl.resetKeyboardNavigation()
          print("Mission Control keyboard controls released")
        }
      } catch {
        print("error: \(error.localizedDescription)")
      }
    }

    guard shouldEnable, !missionControlNavigationPrepared,
      !missionControlNavigationPreparing, !commandInFlight
    else { return }
    let topology = runtime.snapshot()
    guard !topology.isEmpty,
      let targetDisplay = resolver.resolve(in: topology, preferPointer: true)
    else { return }

    missionControlNavigationPreparing = true
    defer { missionControlNavigationPreparing = false }
    switch missionControl.beginKeyboardNavigation(on: targetDisplay, topology: topology) {
    case .success(let number):
      missionControlNavigationPrepared = true
      print("Mission Control keyboard navigation ready on Desktop \(number)")
    case .failure:
      // Dock publishes the Mission Control root before its thumbnails settle.
      // Retry on the next monitor tick rather than treating that transient as an error.
      break
    }
  }

  private func handle(_ command: HotKeyCommand) {
    guard !commandInFlight else {
      print("Ignored shortcut while another Space command is in flight")
      return
    }
    commandInFlight = true
    defer { commandInFlight = false }

    let topology = runtime.snapshot()
    let missionControlVisible = missionControl.isVisible()
    guard !topology.isEmpty,
      let targetDisplay = resolver.resolve(
        in: topology,
        preferPointer: missionControlVisible
      )
    else {
      print("error: could not resolve the target display/Space topology")
      return
    }
    switch command {
    case .desktop(let number):
      switchToDesktop(number, on: targetDisplay, topology: topology)
    case .activateDesktop(let number):
      activateDesktop(number: number, on: targetDisplay, topology: topology)
    case .create:
      createDesktop(on: targetDisplay, topology: topology)
    case .activate(let offset):
      activateDesktop(offset: offset, on: targetDisplay, topology: topology)
    case .reorder(let offset):
      reorderDesktop(offset: offset, on: targetDisplay, topology: topology)
    case .deleteActive:
      deleteDesktop(on: targetDisplay, topology: topology)
    case .enterActive:
      enterDesktop(on: targetDisplay, topology: topology)
    }
  }

  private func switchToDesktop(
    _ number: Int,
    on targetDisplay: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) {
    guard
      let desktop = SpaceTopology.desktop(
        number: number,
        on: targetDisplay.topologyIdentifier,
        displays: topology
      )
    else {
      print("Desktop \(number) does not exist on \(targetDisplay.topologyIdentifier); no action")
      return
    }
    if missionControl.isVisible() {
      switch missionControl.selectDesktop(desktop, on: targetDisplay, topology: topology) {
      case .success:
        print("Selected Desktop \(number) from Mission Control (space=\(desktop.id))")
      case .failure(let error):
        print("error: \(error.localizedDescription)")
      }
      return
    }
    guard
      let globalNumber = SpaceTopology.globalDesktopNumber(
        for: desktop.id,
        displays: topology
      ), globalNumber <= Self.maximumSymbolicDesktop
    else {
      print("error: Desktop \(number) has no macOS symbolic shortcut route")
      return
    }
    let action = Self.firstDesktopAction + UInt32(globalNumber - 1)
    guard runtime.postSymbolicHotKey(action) else {
      print("error: macOS rejected symbolic Desktop action \(action)")
      return
    }
    print(
      "Switching \(targetDisplay.source) display to Desktop \(number) "
        + "(space=\(desktop.id), native-action=\(action))"
    )
  }

  private func createDesktop(
    on targetDisplay: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) {
    let count =
      topology.first {
        $0.identifier == targetDisplay.topologyIdentifier
      }?.regularDesktops.count ?? 0
    print("Creating Desktop \(count + 1) on the \(targetDisplay.source) display…")
    switch missionControl.createDesktop(on: targetDisplay, before: topology) {
    case .success(let spaceID):
      missionControlNavigationPrepared = true
      print(
        "Created and activated Desktop \(count + 1) (space=\(spaceID)); "
          + "Mission Control remains open—press Return to enter"
      )
    case .failure(let error):
      print("error: \(error.localizedDescription)")
    }
  }

  private func activateDesktop(
    offset: Int,
    on targetDisplay: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) {
    switch missionControl.activateAdjacentDesktop(
      offset: offset,
      on: targetDisplay,
      topology: topology
    ) {
    case .success(let number):
      print("Activated Desktop \(number); Mission Control remains open")
    case .failure(let error):
      print("error: \(error.localizedDescription)")
    }
  }

  private func activateDesktop(
    number: Int,
    on targetDisplay: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) {
    switch missionControl.activateDesktop(
      number: number,
      on: targetDisplay,
      topology: topology
    ) {
    case .success:
      print("Activated Desktop \(number); Mission Control remains open")
    case .failure(let error):
      print("error: \(error.localizedDescription)")
    }
  }

  private func reorderDesktop(
    offset: Int,
    on targetDisplay: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) {
    switch missionControl.reorderActiveDesktop(
      offset: offset,
      on: targetDisplay,
      topology: topology
    ) {
    case .success(let number):
      print("Active Desktop is now at position \(number)")
    case .failure(let error):
      print("error: \(error.localizedDescription)")
    }
  }

  private func deleteDesktop(
    on targetDisplay: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) {
    let now = Date()
    guard now.timeIntervalSince(lastDeleteAt) >= 0.35 else { return }
    lastDeleteAt = now
    switch missionControl.deleteActiveDesktop(on: targetDisplay, topology: topology) {
    case .success(let number):
      print("Deleted Desktop \(number)")
    case .failure(let error):
      print("error: \(error.localizedDescription)")
    }
  }

  private func enterDesktop(
    on targetDisplay: TargetDisplay,
    topology: [DisplaySpaceSnapshot]
  ) {
    switch missionControl.enterActiveDesktop(on: targetDisplay, topology: topology) {
    case .success(let number):
      print("Entered Desktop \(number)")
    case .failure(let error):
      print("error: \(error.localizedDescription)")
    }
  }
}

@MainActor
private func run() throws {
  setbuf(stdout, nil)
  let options = Options.values(CommandLine.arguments)
  let runtime = try SpaceRuntime()
  let topology = runtime.snapshot()

  if options.probe {
    guard !topology.isEmpty else {
      throw PrototypeError.privateAPI("SkyLight returned no display/Space topology")
    }
    guard let missionControlKey = runtime.symbolicHotKeyValue(32),
      let previousSpaceKey = runtime.symbolicHotKeyValue(79),
      let nextSpaceKey = runtime.symbolicHotKeyValue(81),
      let firstDesktopKey = runtime.symbolicHotKeyValue(118)
    else {
      throw PrototypeError.privateAPI("macOS did not resolve the expected symbolic actions")
    }
    print("ATE-15 read-only probe (Accessibility trusted: \(AXIsProcessTrusted()))")
    for display in topology {
      let entries = display.spaces.enumerated().map { index, space in
        let kind = space.isFullscreen ? "fullscreen" : "desktop"
        let current = space.id == display.currentSpaceID ? "*" : ""
        return "\(index + 1):\(space.id)[\(kind)]\(current)"
      }.joined(separator: ", ")
      print("  display=\(display.identifier) spaces={\(entries)}")
    }
    print("Required SkyLight topology and symbolic-hotkey symbols: available")
    print(
      "Symbolic actions: Mission Control key=\(missionControlKey.0) "
        + "Previous/next Space keys=\(previousSpaceKey.0)/\(nextSpaceKey.0) "
        + "Desktop 1 key=\(firstDesktopKey.0)"
    )
    print("No preferences were written and Mission Control was not opened")
    return
  }

  guard accessibilityIsTrusted(requestIfNeeded: options.requestAccessibility) else {
    throw PrototypeError.accessibilityPermission
  }
  guard !topology.isEmpty else {
    throw PrototypeError.privateAPI("SkyLight returned no display/Space topology")
  }
  let processLock = try SingletonProcessLock()
  let application = NSApplication.shared
  application.setActivationPolicy(.accessory)
  let controller = SpaceControlController(runtime: runtime)
  try controller.start()
  withExtendedLifetime((controller, processLock, runtime)) {
    application.run()
  }
}

do {
  try run()
} catch {
  fputs("error: \(error.localizedDescription)\n", stderr)
  exit(EXIT_FAILURE)
}
