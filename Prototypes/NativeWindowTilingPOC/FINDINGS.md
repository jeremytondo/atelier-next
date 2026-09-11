# ATE-13 native macOS window-control findings

> Historical experiment report. Read [REVIEW.md](REVIEW.md) for the subsequent
> audit and revised assessment. The owned-window success and independent-client
> failures reproduce, but the broad rejection of synthetic shortcuts and the
> recommendation to prioritize dragging are superseded by evidence from Loop,
> WindowKeys, BetterTouchTool, and Karabiner. Original observations below are
> retained to make the change in interpretation traceable.

> Subsequent local validation confirmed native cross-process menu invocation in
> TextEdit for left, right, top-left, and fill. See the
> [validation record](Evidence/2026-09-10-menu-validation/README.md), including
> the one-point restoration discrepancy and remaining coverage limits.

Status: exploratory research, not a production API decision  
Test environment: macOS 26.5.2 (build 25F84), Apple silicon  
Scope: native desktop tiling; Spaces control has not yet been investigated

## Executive summary

Native macOS tiling is not just a window-frame change. It is a stateful request
between the AppKit client that owns a window and the WindowManager service.

We proved that an application can invoke AppKit's private tiling selectors on
its own `NSWindow` and get genuine system tiling. We also proved that knowing a
foreign window's WindowServer number and private WindowManagement identifier is
not enough to tile it from another WindowManagement client. A second client is
ignored even when it runs inside the process that owns the window.

We then tested whether an Accessibility-authorized controller could deliver the
documented tiling shortcut to another application, allowing that application's
own AppKit client to perform the request. On this macOS build, both PID-targeted
and global synthetic tiling shortcuts were ignored. A PID-targeted synthetic
Command-M minimized the same TextEdit window, establishing that permissions,
focus, and general synthetic input delivery were working.

The current conclusion is therefore:

- Native tiling is proven for windows we own.
- Direct private WindowManagement transactions are not a foreign-window API.
- Synthetic keyboard shortcuts are not a viable native-tiling transport on the
  tested macOS build.
- Arbitrary foreign-window control still needs another mechanism. The next
  promising experiment is a synthetic title-bar drag into a system tiling zone.

## What “native tiling” means

There are two materially different outcomes:

1. **Native tiled state:** WindowManager records the placement, AppKit performs
   its native animation and resizing, and commands such as Return to Previous
   Size participate in the system state machine.
2. **Matching geometry:** A controller calculates a rectangle and assigns it
   through Accessibility. The window may look tiled, but macOS need not consider
   it part of the native tiling state.

ATE-13 is investigating the first outcome. WindowServer bounds are used to
measure movement, while WindowManager logs distinguish native tiling from an
ordinary frame change.

## Experiment results

| Experiment | Result | What it established |
| --- | --- | --- |
| Invoke `_zoomLeft:` on an owned `NSWindow` | Success | Private AppKit selectors enter genuine native tiled state. |
| Submit a `WindowManagement.framework` transaction for another process's fixture window | Ignored | The private identifier is not sufficient authority to control a foreign window. |
| Ask a newly created `NSWMWindowCoordinator` to tile an owned window | Ignored | Being in the owning process is insufficient when a different AppKit client registered the window. |
| Send Fn-Control-Left to the fixture with `CGEventPostToPid` | Ignored | Direct event delivery does not make the fixture perform native tiling. |
| Send Fn-Control-Left to a frontmost TextEdit document using PID-targeted and global delivery | Ignored | The result is not specific to the deliberately bare fixture. |
| Send Command-M to that same TextEdit PID | Success | Accessibility authorization, focus, and ordinary synthetic shortcut delivery were functioning. |

## Private API surface discovered

### SkyLight

The prototype dynamically loads:

- `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`
- `SLSMainConnectionID`
- `SLSGetWindowBounds`

This worked without disabling System Integrity Protection. SkyLight is used for
observation in this prototype: it supplies the WindowServer connection and
authoritative before/after bounds.

### AppKit

The tested `NSWindow` class responds to these runtime selectors:

- `_zoomLeft:`, `_zoomRight:`, `_zoomTop:`, `_zoomBottom:`
- `_zoomTopLeft:`, `_zoomTopRight:`, `_zoomBottomLeft:`, `_zoomBottomRight:`
- `_zoomFill:`, `_zoomCenter:`, `_zoomUntile:`
- `_persistentIdentifierForWindowManagement`

Calling `_zoomLeft:` on the prototype's own window moved it from
`x=375 y=141 width=720 height=452` to
`x=0 y=30 width=735 height=894`. WindowManager logged the operation as an
`Add Tiled Window (clientRequest)` for the left half.

The private persistent identifier is a UUID-like string. It is distinct from
the public-facing `CGWindowID`/`NSWindow.windowNumber`.

### WindowManagement.framework

Runtime inspection identified the relevant classes and methods:

- `WMClientWindowManager`
- `WMWindowTransaction`
- `WMWindowTransactionAction`
- `_WMRequestTilingPositionActionInfo`
- `_WMWindowTilingState`
- `NSWMWindowCoordinator`
- `_WMWindow`

The constructed transaction path was:

1. Create `_WMRequestTilingPositionActionInfo` with a private window identifier
   and tiling position.
2. Create a `WMWindowTransactionAction` from that request.
3. Add the action to a `WMWindowTransaction`.
4. Submit it through `WMClientWindowManager.performWindowTransaction:`.

The service accepted the submission call but did not move the foreign window
or log an `Add Tiled Window` operation.

The discovered tiling-position values were:

| Value | Position | Value | Position |
| ---: | --- | ---: | --- |
| 1 | top | 11 | bottom-right |
| 2 | left | 12 | left-and-right |
| 3 | bottom | 13 | right-and-left |
| 4 | right | 14 | top-and-bottom |
| 5 | center | 15 | bottom-and-top |
| 6 | fill | 16 | quarters |
| 7 | untile | 17 | right-quarters |
| 8 | top-left | 18 | left-three-up |
| 9 | top-right | 19 | right-three-up |
| 10 | bottom-left | 20 | top-three-up |
| — | — | 21 | bottom-three-up |

These values are undocumented and must not be treated as stable ABI.

## Why direct foreign transactions failed

The important control was the second `NSWMWindowCoordinator` in the same
process. It could connect to WindowManager and submit a request, but it could
not tile the `NSWindow` that AppKit's original coordinator had registered.

That makes a simple process-level permission explanation unlikely. The evidence
instead points to a per-client association between:

- the WindowManagement connection,
- its registered `_WMWindow` objects,
- the owning AppKit coordinator, and
- the callback path that applies WindowManager's requested geometry to the
  actual `NSWindow`.

The exact enforcement mechanism remains private. It may include connection
identity, registration state, audit tokens, private entitlements, or a
combination. What is established is that replaying a valid-looking transaction
from an independent client does not inherit ownership.

## Does the target application implement tiling?

Usually, no. Standard applications inherit the behavior from AppKit's
`NSWindow`. SwiftUI, Catalyst, Electron, and other frameworks commonly end in an
AppKit-owned top-level window and therefore may receive the system capability
without implementing these private selectors themselves.

The window must still be eligible. Fixed-size windows, panels, modal windows,
games, or highly customized windows may not participate. More importantly, the
request still needs to travel through the AppKit client that owns and registered
that window.

## Synthetic keyboard-shortcut experiment

Apple documents Fn-Control-Left as the shortcut for moving the active window to
the left half, with corresponding shortcuts for right, top, bottom, fill,
center, and return to the previous size. See
[Mac window tiling icons and keyboard shortcuts](https://support.apple.com/guide/mac-help/mchl9674d0b0/mac).

The experiment tested both:

- `CGEventPostToPid`, targeting TextEdit's PID directly; and
- `CGEvent.post(tap: .cghidEventTap)`, after confirming TextEdit was frontmost.

The controls ruled out the common failure modes:

- `AXIsProcessTrusted()` returned true.
- `CGPreflightPostEventAccess()` returned true.
- `IsSecureEventInputEnabled()` returned false.
- TextEdit owned a normal, resizable document window.
- TextEdit was the frontmost application.
- Accessibility inspection showed TextEdit's Left item registered virtual key
  123 with modifier value 28, corresponding to Control + Fn with no Command.
- Both a simple key-down/key-up encoding and explicit modifier transitions were
  tested.
- PID-targeted Command-M successfully set the same window's `AXMinimized` state
  to true.
- WindowManager logged no tiled-window transition for the synthetic tiling
  attempts.

Therefore ordinary CoreGraphics event synthesis works across the process
boundary, but the system's tiling shortcuts are not dispatched through that
path on this build. We should not build the command API around synthetic tiling
keystrokes.

## Implications for the command API

The command surface should remain independent of its execution backend. A
future command might look conceptually like `tile(window, placement)`, while
capability detection chooses among implementations.

Current backend assessment:

| Backend | Native state | Foreign windows | Current assessment |
| --- | --- | --- | --- |
| Private `NSWindow` selector | Yes | No | Proven for Atelier-owned windows; runtime-gate it. |
| Independent WindowManagement transaction | Intended, but rejected | No | Do not pursue as a normal client API without new ownership evidence. |
| Synthetic tiling shortcut | Intended, but ignored | No on tested build | Rejected as a dependable transport. |
| Accessibility frame assignment | No | Usually | Viable compatibility fallback, but not native tiling. |
| Synthetic title-bar drag to a tiling zone | Potentially | Potentially | Best next menu-free experiment. |
| Target-side cooperation or injected code | Yes | Only with cooperation/injection | Technically plausible, generally unsuitable for arbitrary hardened apps. |

Private APIs should remain optional and runtime-resolved. They have no source,
binary, behavioral, or App Store compatibility guarantee.

## Next experiment

Test a controlled title-bar drag of a disposable TextEdit window into the
screen's native left tiling zone:

1. Locate the target window and title-bar point through Accessibility.
2. Confirm the target is frontmost and the pointer path is safe.
3. Post mouse-down, drag, and mouse-up events to the screen edge.
4. Restore the user's pointer position afterward.
5. Compare WindowServer bounds and require a WindowManager `clientRequest`
   tiling log as the success condition.

This is worth testing because macOS explicitly supports edge-drag tiling, and
the gesture is handled at the WindowServer/WindowManager interaction boundary
rather than through the rejected foreign transaction or keyboard paths. Apple
documents edge dragging as a native tiling method in
[Tile windows on Mac](https://support.apple.com/guide/mac-help/tile-app-windows-mchlef287e5d/mac).

## Remaining unknowns

- Whether synthetic title-bar dragging produces native tiled state.
- The precise WindowManager ownership check used for transaction requests.
- Whether any supported or private cross-process API can request tiling without
  menu invocation, event simulation, or target-side cooperation.
- Behavior across other macOS versions and hardware configurations.
- Native Spaces enumeration, creation, movement, and window assignment. Spaces
  has not been prototyped yet.
