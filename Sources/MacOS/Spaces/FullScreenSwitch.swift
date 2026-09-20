import AppKit
import ApplicationServices
import os

/// Enters a full-screen Space through its exact window, allowing Dock to
/// perform one native transition. Discovery happens before anything is
/// activated. A missing, stale, or unresponsive target has no shortcut
/// fallback. The workspace holds its command guard until Space and focus
/// have settled, so later commands cannot overlap this activation.
struct FullScreenSwitch: Sendable {
  let skyLight: SkyLight
  private static let log = Logger(subsystem: "com.elevenideas.Atelier", category: "spaces")

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
    guard let activation = skyLight.windowActivation else {
      return .refused("Direct full-screen switching is unavailable on this macOS.")
    }
    let result = await Background.run {
      activate(space: space, display: display, expecting: expecting, with: activation)
    }
    switch result {
    case .stopped(let dispatch): return dispatch
    case .sent(let window, let origin):
      return await FullScreenTransition(space: space, display: display, origin: origin?.space)
        .confirm(
          displays: { DisplaySpaces.decode(skyLight.managedDisplaySpaces()) },
          isFocused: { await Background.run { isFocused(window) } },
          restoreOrigin: {
            guard let origin, !activation.restoreFront(origin.process, space: origin.space)
            else { return }
            Self.log.notice("macOS would not restore the front app of Space \(origin.space)")
          })
    }
  }

  /// No AX element leaves this background operation. Finding the element
  /// waits on the app, so what the target rests on is read again after it,
  /// last of all before activation.
  private func activate(
    space: UInt64, display: String, expecting: [DisplaySpaces], with activation: WindowActivation
  ) -> Activation {
    let raw = skyLight.managedDisplaySpaces()
    guard DisplaySpaces.decode(raw) == expecting else { return .stopped(.changed) }
    guard let target = FullScreenWindow.read(space: space, on: display, from: raw),
      target.app != getpid(),
      let process = activation.process(for: target.app),
      let element = resolve(target, with: activation)
    else {
      return .stopped(.refused("The full-screen window is unavailable or did not answer."))
    }

    // The origin Space's front app is restored afterwards when it can be
    // told; when it cannot, the switch goes ahead without.
    var origin: Origin?
    if let previous = expecting.first(where: { $0.id == display })?.currentSpace,
      previous != space,
      let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != target.app,
      let previousProcess = activation.process(for: app.processIdentifier)
    {
      origin = Origin(space: previous, process: previousProcess)
    }

    let latest = skyLight.managedDisplaySpaces()
    guard DisplaySpaces.decode(latest) == expecting,
      FullScreenWindow.read(space: space, on: display, from: latest) == target,
      skyLight.spaces(ofWindow: target.id) == [space],
      activation.process(for: target.app) == process
    else { return .stopped(.changed) }

    guard activation.focus(window: target.id, in: process) else {
      return .stopped(.refused("macOS would not bring the full-screen window forward."))
    }
    // A raise that times out can still take effect. Keep the command guard
    // and observe the actual Space and focus; returning early would let
    // another command race the unfinished switch.
    _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    return .sent(target, origin)
  }

  private func matches(_ element: AXUIElement, _ target: FullScreenWindow) -> Bool {
    var pid: pid_t = 0
    return AXUIElementGetPid(element, &pid) == .success && pid == target.app
      && skyLight.windowID(of: element) == target.id
      && element.attribute(kAXRoleAttribute) as? String == kAXWindowRole
  }

  private func resolve(_ target: FullScreenWindow, with activation: WindowActivation)
    -> AXUIElement?
  {
    let deadline = ContinuousClock.now + .milliseconds(500)
    // Key and main windows can remain published when AXWindows omits them.
    // A non-answer stops here: scanning a frozen app cannot help.
    guard
      let values = AXUIElementCreateApplication(target.app).attributes([
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
      if matches(candidate, target) { return candidate }
    }

    // An app lists only the windows of the Spaces being shown, so this scan
    // is the usual way to a full-screen window. These numbers belong to AX
    // elements, including descendants. They may be sparse in long-lived
    // apps, so time bounds the search, not an ID cap.
    let scanDeadline = min(deadline, ContinuousClock.now + .milliseconds(250))
    var number: UInt64 = 0
    while ContinuousClock.now < scanDeadline {
      if let candidate = activation.remoteElement(in: target.app, number: number),
        matches(candidate, target)
      {
        return candidate
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
