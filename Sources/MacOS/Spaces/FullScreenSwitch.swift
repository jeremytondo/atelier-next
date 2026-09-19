import AppKit
import ApplicationServices

/// Enters a full-screen Space through its exact window, allowing Dock to
/// perform one native transition. Discovery happens before anything is
/// activated. A missing, stale, or unresponsive target has no shortcut
/// fallback. The workspace holds its command guard until Space and focus
/// have settled, so later commands cannot overlap this activation.
struct FullScreenSwitch: Sendable {
  let skyLight: SkyLight

  private struct Origin: Sendable {
    let space: UInt64
    let process: WindowActivation.Process
  }

  private enum Activation: Sendable {
    case sent(FullScreenWindow, Origin?)
    case stopped(SpaceDispatch)
  }

  func switchSpace(to space: UInt64, on display: String, expecting: [DisplaySpaces]) async
    -> SpaceDispatch
  {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
      skyLight.windowActivation != nil
    else { return .refused("Direct full-screen switching is unavailable on this macOS.") }

    let result = await Background.run {
      activate(space: space, display: display, expecting: expecting)
    }
    let window: FullScreenWindow
    let origin: Origin?
    switch result {
    case .sent(let target, let previous):
      window = target
      origin = previous
    case .stopped(let dispatch): return dispatch
    }

    let deadline = ContinuousClock.now + .seconds(3)
    var focusedSince: ContinuousClock.Instant?
    while ContinuousClock.now < deadline {
      let displays = DisplaySpaces.decode(skyLight.managedDisplaySpaces())
      guard let screen = displays.first(where: { $0.id == display }),
        screen.spaces.contains(where: { $0.id == space && !$0.isDesktop })
      else { break }
      if screen.currentSpace == space,
        await Background.run({ isFocused(window) })
      {
        let now = ContinuousClock.now
        if let focusedSince, now - focusedSince >= .milliseconds(75) {
          guard restore(origin) else {
            return .uncertain(
              "macOS switched Spaces but could not preserve the previous Space's focus.")
          }
          return .sent
        }
        if focusedSince == nil { focusedSince = now }
      } else {
        focusedSince = nil
      }
      do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
    }
    return .uncertain("macOS did not confirm the full-screen Space and its focused window.")
  }

  /// No AX element leaves this background operation. Both the app's launch
  /// identity and WindowServer's owner/membership are checked again after the
  /// AX search, and the Space layout is read last before activation.
  private func activate(space: UInt64, display: String, expecting: [DisplaySpaces]) -> Activation {
    let raw = skyLight.managedDisplaySpaces()
    guard DisplaySpaces.decode(raw) == expecting else { return .stopped(.changed) }
    guard let target = FullScreenWindow.read(space: space, on: display, from: raw),
      target.app != getpid(), owns(target, space: space),
      let activation = skyLight.windowActivation,
      let process = activation.process(for: target.app),
      let element = resolve(target)
    else {
      return .stopped(.refused("The full-screen window is unavailable or did not answer."))
    }
    guard activation.process(for: target.app) == process,
      owns(target, space: space), matches(element, target)
    else {
      return .stopped(.refused("The full-screen window changed before Atelier could focus it."))
    }

    var origin: Origin?
    if let previous = expecting.first(where: { $0.id == display })?.currentSpace,
      previous != space,
      let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != target.app
    {
      guard let previousProcess = activation.process(for: app.processIdentifier) else {
        return .stopped(.refused("macOS did not identify the previous Space's focused app."))
      }
      origin = Origin(space: previous, process: previousProcess)
    }

    let latest = skyLight.managedDisplaySpaces()
    guard DisplaySpaces.decode(latest) == expecting,
      FullScreenWindow.read(space: space, on: display, from: latest) == target
    else { return .stopped(.changed) }

    let dispatch = activation.focus(window: target.id, in: process)
    switch dispatch {
    case .refused, .changed: return .stopped(dispatch)
    case .sent:
      AXUIElementSetMessagingTimeout(element, WindowCensus.requestTimeLimit)
      _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    case .uncertain: break
    }
    // Once activation was posted, even a timed-out AXRaise can still take
    // effect. Keep the command guard and observe the actual Space and focus;
    // returning early would let another command race the unfinished switch.
    return .sent(target, origin)
  }

  private func restore(_ origin: Origin?) -> Bool {
    guard let origin else { return true }
    let displays = DisplaySpaces.decode(skyLight.managedDisplaySpaces())
    guard
      let display = displays.first(where: { $0.spaces.contains(where: { $0.id == origin.space }) })
    else { return true }
    // A user switch back to the origin must not be overwritten by a repair.
    guard display.currentSpace != origin.space else { return false }
    return skyLight.restoreFront(origin.process, space: origin.space)
  }

  private func owns(_ target: FullScreenWindow, space: UInt64) -> Bool {
    guard skyLight.spaces(ofWindow: target.id) == [space],
      let descriptions = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.id)
        as? [[String: Any]]
    else { return false }
    return descriptions.contains {
      ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.id
        && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.app
        && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }
  }

  private func matches(_ element: AXUIElement, _ target: FullScreenWindow) -> Bool {
    var pid: pid_t = 0
    return AXUIElementGetPid(element, &pid) == .success && pid == target.app
      && skyLight.windowID(of: element) == target.id
      && element.attribute(kAXRoleAttribute) as? String == kAXWindowRole
  }

  private func resolve(_ target: FullScreenWindow) -> AXUIElement? {
    let deadline = ContinuousClock.now + .milliseconds(500)
    let app = AXUIElementCreateApplication(target.app)
    AXUIElementSetMessagingTimeout(app, WindowCensus.requestTimeLimit)
    // Key and main windows can remain published when AXWindows omits them.
    // A non-answer stops here: scanning a frozen app cannot help.
    guard
      let values = app.attributes([
        kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute,
      ])
    else { return nil }
    var published = values[0] as? [AXUIElement] ?? []
    for value in values.dropFirst() {
      if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
        published.append(unsafeDowncast(value, to: AXUIElement.self))
      }
    }
    for candidate in published {
      guard ContinuousClock.now < deadline else { return nil }
      AXUIElementSetMessagingTimeout(candidate, 0.03)
      if matches(candidate, target) { return candidate }
    }

    guard skyLight.canResolveRemoteElements else { return nil }
    // These numbers belong to AX elements, including descendants. They may
    // be sparse in long-lived apps, so time bounds the search, not an ID cap.
    let scanDeadline = min(deadline, ContinuousClock.now + .milliseconds(250))
    var number: UInt64 = 0
    while ContinuousClock.now < scanDeadline {
      if let candidate = skyLight.remoteElement(in: target.app, number: number) {
        AXUIElementSetMessagingTimeout(candidate, 0.03)
        if matches(candidate, target) { return candidate }
      }
      number += 1
    }
    return nil
  }

  private func isFocused(_ target: FullScreenWindow) -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app else {
      return false
    }
    let app = AXUIElementCreateApplication(target.app)
    AXUIElementSetMessagingTimeout(app, 0.1)
    guard let window = app.element(kAXFocusedWindowAttribute) else { return false }
    return skyLight.windowID(of: window) == target.id
  }
}
