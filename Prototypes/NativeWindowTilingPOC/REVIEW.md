# ATE-13 native window tiling review

Native macOS tiling remains a credible foundation for configurable shortcuts and
launch-then-tile workflows. The existing experiments establish useful facts, but
their negative conclusions are broader than their controls justify. Other apps
provide concrete evidence of routes the prototype did not test.

**Local follow-up:** after granting Accessibility to the responsible `node`
runtime, semantic menu invocation produced native left, right, top-left, and
fill tiling in TextEdit. WindowManager logged each requested tiled state and
subsequent untile. Restoration differed by up to one point per frame component.
The user then tried the focused-window tester and reported that it “actually
works pretty well.” This is positive qualitative feedback; systematic visual,
latency, compatibility, and multi-window checks remain outstanding. See the
[new evidence](Evidence/2026-09-10-menu-validation/README.md).

The strongest implementation lead is **Accessibility invocation of native menu
commands identified by their semantic identifiers**. Loop implements this in
public source; WindowKeys describes a menu-based native implementation. A second
lead is **virtual-HID keyboard delivery**: Karabiner documented a device-identity
issue that prevented precisely these shortcuts from working and shipped a fix.
BetterTouchTool additionally documents native tiling and arrangement actions
that do not require assigned system shortcuts. Its developer explicitly confirms
menu invocation for the Sequoia native side-by-side integration; the exact
transport of every current action remains unverified.[^1][^2][^3][^4][^5][^6][^20]

The recommendation is to pursue a native-only capability layer using semantic
menu actions first. An arbitrary-window, background, atomic desktop-layout API
has **not** been demonstrated. That more demanding claim should remain separate
from the already credible shortcut and foreground automation use cases.

## Scope and evidence

This review covers the ATE-13 issue description, the prototype at baseline
`db431b0`, its original findings, fresh local control runs, and primary sources
from other applications. The Linear issue has no comments or attached experiment
records. Its requirement is native behavior that feels seamless; the issue does
not prohibit menu invocation.[^7]

The local system still reports macOS 26.5.2, build 25F84, on Apple silicon. The
fresh test records are retained in [Evidence](Evidence/2026-09-10-review/README.md).
External documentation was accessed September 10, 2026. Historical Sequoia
results are identified as such; they do not certify behavior on Tahoe.

“Native” means invoking Apple's tiling operation and obtaining its associated
state and behavior. Setting an Accessibility rectangle is insufficient. Desktop
tiling, fullscreen Split View, and Mission Control Spaces are separate features.
Apple's documentation exposes desktop placements and arrangements through the
Window menu, shortcuts, and pointer interactions.[^8][^9]

There are four evidence levels throughout this report: locally reproduced;
observed in implementation source; documented by an application's developer;
and proposed for testing. They are not interchangeable.

## Audit of the existing experiments

| Existing conclusion | Review assessment | Evidence and limitation |
| --- | --- | --- |
| An owned `NSWindow` can enter native tiled state through `_zoomLeft:` | Reproduced | Bounds changed from `(375,141,720,452)` to `(0,30,735,894)`; WindowManager recorded native `leftHalf` and the original untiled frame. |
| A separate WindowManagement client cannot tile the foreign fixture | Reproduced for this construction | Window 175691 retained `(395,146,680,432)` after submitting position 2. This is an observed no-op, not a returned authorization denial. |
| A new coordinator in the owning process cannot tile the window | Reproduced for this construction | Window 175696 retained its original bounds. The new coordinator was not shown to be registered or initialized equivalently to AppKit's working coordinator. |
| CoreGraphics Fn-Control event delivery failed while Command-M worked | Historical result, not freshly reproduced | Initial review runs lacked Accessibility authorization; it was subsequently granted for menu tests. The keyboard experiment was not rerun. The checked-in code supports the basic key-down/key-up experiment, but not all documented variants. |
| Synthetic shortcuts cannot be a native transport | Overgeneralized | The tested event encoding and delivery paths failed. Karabiner's virtual-device work establishes a different synthetic input route worth considering. |
| Dragging is the best next experiment | Superseded | Semantic menu invocation has a directly inspectable implementation and avoids the pointer movement intrinsic to dragging. |

The owned-window positive control is strong because geometry and a native state
log agree. The two private-client controls are useful reproducible negatives.
They should lower the priority of replaying the same transaction, but they do
not establish the exact ownership enforcement mechanism.

The bridge constructs a new `NSWMWindowCoordinator`, extracts its manager, and
submits a request. It does not demonstrate equivalent window registration,
connection readiness, callback handling, or transaction completion. The fixture
announces its private identifier shortly after creating its window; nonzero
WindowServer bounds do not establish WindowManagement registration readiness.
Consequently, incomplete client setup and timing remain competing explanations
alongside client association or authorization. The defensible statement is:
**a window ID and this independent-client construction are insufficient**.

The same-process negative makes a simple “different PID” explanation inadequate,
but does not isolate client ownership as the cause. A useful additional control
would submit the same action through AppKit's actual working coordinator, with
readiness established, and compare its transaction and callback sequence with
the independent client. This is a bounded follow-up, not the leading product
implementation path.

### Measurement and reproducibility problems

The baseline harness treats any changed bounds as successful native tiling.
That permits false positives from an ordinary move, launch-time adjustment, an
intermediate animation sample, or even an optional bounds value becoming `nil`.
It also does not fail a smoke test just because the requested placement was
ignored. Process exit success therefore cannot be read as feature success.

The review changes the cross-process result labels to “bounds changed” and
requires valid before/after samples. The new menu experiment adds stable-sample
observation and native Return to Previous Size as a behavioral control. These
improvements do not make the older harness a production test suite: it still
needs expected-placement checks, bounded fixture startup, and explicit
machine-readable success criteria before automated certification.

The findings say explicit modifier transitions were tested. No such event
sequence exists in the committed implementation, and no raw historical
transcript is present. This does not prove the experiment never happened; it
means that variant cannot currently be independently reproduced from the repo.
Likewise, the discovered private position values for arrangements are recorded
without a checked-in derivation or behavioral tests. Preserve them as candidate
values, not verified API coverage.

There is also an unrelated robustness overclaim: runtime lookup does not ensure
safe behavior after an OS update. The bridge checks framework/class availability
but sends several private Objective-C messages without checking every selector
or signature. `--probe` primarily checks SkyLight observation and AppKit
selectors, not the complete transaction path. The README now states that limit.

Finally, the proposed drag test required a `clientRequest` log reason. That is
unnecessarily specific: a native gesture may be recorded under another reason.
Use native state, restoration, and correlated logs together. Neither a missing
log line nor the absence of a particular reason string is sufficient failure
evidence.

## What other applications actually do

| Application | Evidence | Relevance to ATE-13 |
| --- | --- | --- |
| **Loop** | Source finds native menu items by `AXIdentifier`, then invokes Accessibility press. | Best inspectable backend reference; its native mode explicitly focuses the target. |
| **WindowKeys** | Developer documents native tiling through system menu commands, custom shortcuts, and multilingual support. | Direct product precedent for the core shortcut requirement. |
| **BetterTouchTool** | Developer confirms menu invocation for native side-by-side; general resizing can fall back to non-native. | Additional menu-route precedent; current dedicated native actions still need separate verification. |
| **Karabiner-Elements** | Maintainer identified the Apple-device identity dependency; release notes record the virtual-keyboard identity change. | Concrete alternative to CoreGraphics Fn-event synthesis. |
| **Keyboard Maestro** | Documents selecting a menu command in the foreground or a specified app. | Suitable workflow prototype for activation and menu actions; native tiling needs verification. |
| **Hammerspoon** | Documents app launch/focus, menu selection, and separate Spaces functionality. | Useful orchestration/reference layer; its own tiling functions should not be assumed to use Apple's engine. |
| **Rectangle** | Inspected standard mover applies a calculated frame. | Good comparison for geometry management; that path does not meet the native-command requirement. |
| **AeroSpace / yabai** | AeroSpace documents its own layouts and emulated workspaces; yabai documents SIP-sensitive functionality. | Useful adjacent architecture research, not evidence that native desktop tiling is solved by their layout engines. |

Sources for the comparison: Loop,[^1][^2] WindowKeys,[^3] BetterTouchTool,[^4]
Karabiner,[^5][^6] Keyboard Maestro,[^10] Hammerspoon,[^11][^12]
Rectangle,[^13] AeroSpace,[^14] and yabai.[^15]

### Loop: a concrete path through the owning application

The inspected Loop revision is
`df26d565e07c82e156b8f1c361bdcf428f32e3a4`. Its `SystemWindowManager.swift`
maps placements to identifiers such as `_zoomLeft:`, `_zoomTopLeft:`,
`_zoomFill:`, and `_zoomUntile:`. It traverses the target application's menu
hierarchy and compares `AXIdentifier`, avoiding dependence on English menu
titles. The source also lists arrangement identifiers including
`_zoomLeftAndRight:` and `_zoomQuarters:`.[^1]

`WindowEngine.swift` enables the native route conditionally, focuses the target,
requires the app to be frontmost and the menu item enabled, and presses that
item. Cross-display operations and unavailable native actions can take its
ordinary frame-resizing path. It also suppresses press errors with `try?`, so
its return value alone is not a completion guarantee.[^2]

This yields a useful architectural distinction: **the same string can identify
a remotely accessible menu command without granting remote access to an
`NSWindow` object**. The Accessibility request asks the owning app to execute
the command. The target's established AppKit machinery can then perform its
normal operation. That is consistent with both successful owned-window tiling
and failed independent-client transactions; no contradiction is required.

The recommended implementation should independently reproduce the mechanism,
check every action result, and expose unsupported actions explicitly. It should
not silently adopt Loop's geometry fallback when the caller requires native
state. Apple's Accessibility action function is public, but AppKit's particular
identifier strings and menu organization are still runtime dependencies.[^16]

### WindowKeys and BetterTouchTool: product precedents

WindowKeys says it needs applications to expose the Window menu's tiling
options. This is a useful capability boundary, not a claim that every window in
every app can be controlled. Its current requirements specify macOS 15.1+;
Apple introduced desktop tiling in macOS 15, so the app's minimum should not be
confused with the feature's introduction.[^3][^8]

BetterTouchTool lists native actions for halves, quarters, fill, center,
restoration, and multi-window arrangements. Examples include action `627` for
left half and `646` for four-window quarters. These numbers belong to BTT's
action API, **not** WindowManagement's position enumeration. Its older Sequoia
release notes also describe integration preserving native animations and shared
edge resizing.[^4][^17]

Follow-up evidence strengthens the implementation assessment. On September 28,
2024, developer Andreas Hegenberg explicitly stated that native side-by-side
invokes Window → Move & Resize → Left & Right. This establishes menu invocation
for that integration, although it does not identify its low-level dispatch
function.[^20]

In January 2025, Hegenberg explained that general resizing uses native equivalents
when available and otherwise falls back to non-native behavior. While debugging
language and application compatibility, he examined AppKit's
`MenuCommands.loctable` and the target app's menu structure. This suggests
localized menu lookup was involved in that version; it does not establish
Loop-style `AXIdentifier` matching.[^21]

These historical disclosures do not establish the implementation of every
current dedicated native action, background targeting, or atomic layout
transactions. They do establish that BTT is another menu-route precedent.
For native-only validation, successful resizing through a general BTT action
is insufficient evidence because it may have used the documented fallback.

### Karabiner: why the keyboard result needs narrowing

In issue #3879, Karabiner's maintainer first removed an unwanted Fn-arrow
translation, but native snapping still failed. The maintainer then reported
success after changing the virtual device's vendor/product identity to match a
Magic Keyboard. A later comment reported resolution in beta 15.0.14. Stable
15.1.0 release notes, dated October 6, 2024, document the Apple-keyboard identity
change and removal of implicit Fn-arrow conversion.[^5][^6]

This is strong evidence that native tiling's input handling depends on more than
the apparent modifier combination. It does **not** establish that device identity
is the cause of the current prototype's failure. That requires comparing actual
received events and device-level behavior on the same system.

Karabiner's DriverKit project offers a programmable virtual-device client and
lists Tahoe support, but its client must run with root privileges and it uses a
system extension. Building a separately signed driver also requires appropriate
DriverKit entitlements. This is a materially larger deployment commitment than
an Accessibility menu backend. It is a real secondary route, not a small change
to `CGEvent.flags`.[^18]

A cheaper keyboard experiment remains open: give the native menu command an
ordinary non-Fn app shortcut and compare physical and synthetic delivery of
that binding. Apple supports custom shortcuts for existing menu commands. The
binding alone does not supply launch-and-wait orchestration, and no success for
synthetically delivering that remapped binding has been established here.[^19]

## Mapping the goal to achievable capabilities

**Configurable shortcut → native placement:** this has direct product and source
precedent. Register the chosen shortcut, identify the focused eligible window,
resolve the enabled native action, dispatch it, and verify completion. A
configured shortcut need not be translated into Apple's Fn shortcut at all.

**Open or activate an app → tile its window:** technically credible with the
same backend, but app launch is not window readiness. Wait for an eligible
window, choose it explicitly, activate/raise it, confirm focus, then invoke the
native action. A running process may have no document, a startup dialog,
restored documents, or several windows. A fixed delay and “largest window” are
acceptable fixture conveniences, not a general selection policy.

**Rearrange a desktop:** distinguish Apple's built-in arrangements from an
explicit assignment of chosen windows to chosen positions. Native arrangement
commands exist, but the prototype has not measured participant selection,
ordering, or behavior when more windows exist than available positions. A
sequence of per-window native commands offers more explicit targeting but can
require repeated focus changes. No evidence here establishes atomic application
of an arbitrary layout.

**Automatically react to window creation:** use a bounded readiness state
machine and serialize its native commands. Separate a one-shot “arrange now”
workflow from continuous auto-tiling; the latter additionally needs to avoid
feedback loops and respect manual user moves. Treat these as distinct product
capabilities with independent acceptance tests.

**All windows on a desktop:** define what counts: visible standard windows,
minimized windows, hidden apps, windows on each display's current Space, and
windows in fullscreen Spaces are not the same set. More windows than native
layout slots require an explicit overflow policy. Native-only execution cannot
promise arbitrary rectangles or layouts that Apple's commands do not express.

**Spaces:** preserve a separate capability boundary. Hammerspoon documents a
mixture of private APIs and Dock Accessibility, with animation limitations;
yabai documents restricted operations that require partially disabled SIP.
AeroSpace explicitly emulates its workspaces instead of controlling native
Spaces. None of those facts establishes seamless native Spaces control for this
prototype.[^12][^14][^15]

## Recommended validation sequence

| Priority | Experiment | Required observation |
| --- | --- | --- |
| 1 | Cold-menu TextEdit: semantic left, right, quarter, fill, and restore | No preparatory menu opening; valid target identity; successful AX action; settled expected geometry; restored original state; native log corroboration |
| 2 | Repeat against representative AppKit, browser, Electron, and custom-window apps, including a non-English app | Availability and identifiers recorded per app/window; missing and disabled items reported as unsupported |
| 3 | Two windows in one app, then two apps | The selected window moves; others stay unchanged; focus is restored when appropriate; interruption does not redirect later actions |
| 4 | Native two-, three-, and four-window arrangements with an extra bystander | Exact participants, ordering, overflow behavior, shared-edge resizing, and restoration documented |
| 5 | Launch/focus/tile sequences, cold and warm | Readiness and exact-window selection succeed without fixed launch assumptions; failures identify their stage |
| 6 | Current virtual-HID route and remapped non-Fn shortcut | Compare against physical positive controls and current CoreGraphics paths on the same build |
| 7 | Deeper private coordinator investigation | Working-client positive control and readiness/callback evidence before additional foreign-client conclusions |

For each supported workflow, retain command timing, target PID/window identity,
before/after frames, Accessibility errors, permission state, OS build, display
configuration, and relevant tiling preferences. Capture logs around a known
positive control as well as the candidate path. Run repeated trials only after
the basic route works; report observed counts rather than declaring reliability
from one successful action.

Smoothness needs an explicit second-stage assessment: screen recording or human
observation of focus flashes, menu exposure, pointer changes, animations, and
interference from real input. The first phase should establish native state.
The second should establish correct targeting and acceptable experience. A
fast API return is not a measurement of either animation completion or visual
quality.

Synthetic dragging should remain lower priority. It depends on pointer position,
title-bar eligibility, screen-edge configuration, display topology, dwell timing,
and live user input. It is still worth testing if semantic menu dispatch cannot
cover an important eligible window; it is no longer the best first lead.

## Prototype changes and current local limits

The added `--standard-app-menu-smoke-test` performs identifier discovery using
the prototype's own bounded traversal, validates `AXEnabled` and `AXPress`,
uses a disposable single-document TextEdit instance, and attempts native
restoration. It never calculates and assigns a target frame. It checks stable
bounds and reports whether the pointer changed. It remains a research probe,
not a reusable backend or a full native-state oracle.

The package builds successfully. The owned-window positive control and both
independent-client negatives reproduced. The initial menu attempts were blocked
by missing Accessibility authorization; those historical transcripts remain
preserved. After the responsible Node runtime was authorized, all four tested
TextEdit placements produced native tiled states confirmed in WindowManager
logs. Each native restoration removed tiled state and returned geometry within
one point per frame component, but exact equality failed in every trial. The
first strict failure is retained, and the revised probe reports both exact and
tolerant restoration with full deltas. The discrepancy's cause is unresolved.

The root `./tile-window` script exposes `--focused-window` for hands-on testing:
after a five-second countdown, it captures the foreground app's focused window,
invokes the shared native menu dispatcher, and leaves the placement visible.
The dispatcher checks the enabled action and rechecks focus immediately before
invocation. It reports discovery/dispatch time separately from dispatch alone;
neither measures animation completion. Unsupported commands fail without frame
fallback. `untile` uses the same workflow. No global shortcuts are installed.

The user's positive hands-on feedback supports the interaction approach, but
the tested apps, windows, placements, and trial count were not recorded. It
does not establish universal support or a measured latency bound. The
[manual instructions](README.md#try-it-on-your-own-windows) make further trials
repeatable.

The next step is cross-app and multi-window targeting and visual-quality
validation, rather than further proving this single-window dispatch route.
The appropriate ATE-13 decision is to continue with semantic menu invocation,
retain native-only failure semantics, and defer any promise of invisible
background or atomic desktop-wide control until measured.

## Sources

[^1]: Loop, [SystemWindowManager.swift](https://github.com/mrkai77/Loop/blob/df26d565e07c82e156b8f1c361bdcf428f32e3a4/Loop/Core/SystemWindowManager.swift), pinned source; file modification reported January 29, 2026. Native action identifiers and menu discovery.
[^2]: Loop, [WindowEngine.swift](https://github.com/mrkai77/Loop/blob/df26d565e07c82e156b8f1c361bdcf428f32e3a4/Loop/Window%20Management/Window%20Manipulation/WindowEngine.swift), same pinned revision; file modification reported May 14, 2026. Foreground checks, AX press, and frame fallback.
[^3]: Apptorium, [WindowKeys product page and FAQ](https://www.apptorium.com/windowkeys), undated current page. Menu-based mechanism, compatibility, and shortcuts.
[^4]: folivora.AI, [Action JSON Definitions — macOS Native Window Tiling](https://docs.folivora.ai/docs/actions/action-definitions/#macos-native-window-tiling-macos-15), undated current documentation. Native action API and arrangement claims; internal implementation not disclosed.
[^5]: Karabiner-Elements, [issue #3879](https://github.com/pqrs-org/Karabiner-Elements/issues/3879), especially [maintainer's device-identity finding](https://github.com/pqrs-org/Karabiner-Elements/issues/3879#issuecomment-2308839537) and [reported beta resolution](https://github.com/pqrs-org/Karabiner-Elements/issues/3879#issuecomment-2381071748), 2024. Firsthand implementation investigation.
[^6]: Karabiner-Elements, [15.1.0 release notes](https://karabiner-elements.pqrs.org/docs/releasenotes/#karabiner-elements-1510), October 6, 2024. Confirms the virtual-device identity and Fn-translation changes shipped.
[^7]: Atelier, [ATE-13: Explore controlling native macOS window tiling and spaces](https://linear.app/elevenideas/issue/ATE-13/explore-controlling-native-macos-window-tiling-and-spaces), September 10, 2026; private issue accessed through the connected tracker. Local baseline [FINDINGS.md](FINDINGS.md) and [source](Sources/NativeWindowTilingPOC/main.swift); fresh evidence linked above.
[^8]: Apple, [Tile windows on Mac](https://support.apple.com/guide/mac-help/tile-app-windows-mchlef287e5d/mac), current macOS guide. Native interaction routes.
[^9]: Apple, [Mac window tiling icons and keyboard shortcuts](https://support.apple.com/guide/mac-help/mchl9674d0b0/mac), current macOS guide. Placements and arrangements.
[^10]: Keyboard Maestro, [Select or Show a Menu Item](https://wiki.keyboardmaestro.com/action/Select_or_Show_a_Menu_Item), current documentation. Foreground/specific-app menu selection behavior.
[^11]: Hammerspoon, [hs.application](https://www.hammerspoon.org/docs/hs.application.html), current documentation, especially launch/focus and selectMenuItem. Orchestration primitives.
[^12]: Hammerspoon, [hs.spaces](https://www.hammerspoon.org/docs/hs.spaces.html), current documentation. Private/API and Accessibility mix, movement and animation limitations; not a local Tahoe test.
[^13]: Rectangle, [StandardWindowMover.swift](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/WindowMover/StandardWindowMover.swift), source inspected September 10, 2026. The standard mover calls `setFrame` with a calculated rectangle.
[^14]: AeroSpace, [Guide: layouts and emulation of virtual workspaces](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces), current documentation. Distinguishes its layout/workspace model from native Spaces.
[^15]: yabai, [Disabling System Integrity Protection](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection), current project documentation. Scope of SIP-dependent functionality; not a statement that all yabai operation requires disabling SIP.
[^16]: Apple, [AXUIElementPerformAction](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction), API reference. Action dispatch and error behavior.
[^17]: folivora.AI, [Sequoia release notes](https://updates.folivora.ai/sequoia.html), September 15–17, 2024. Native snapping integration and preserved behavior.
[^18]: pqrs.org, [Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice), current project documentation. Virtual devices, Tahoe support, privileged client, and signing requirements.
[^19]: Apple, [Create keyboard shortcuts for apps on Mac](https://support.apple.com/guide/mac-help/create-keyboard-shortcuts-for-apps-mchlp2271/mac), current guide. Custom menu shortcuts and their scope.
[^20]: Andreas Hegenberg, [Frontmost Windows Side-by-side Issue](https://community.folivora.ai/t/frontmost-windows-side-by-side-issue/39392), September 28, 2024, post 2. Explicit developer confirmation of native menu invocation.
[^21]: Andreas Hegenberg, [Native macOS window snapping support?](https://community.folivora.ai/t/native-macos-window-snapping-support/41170), January 3–5, 2025, especially posts 5, 10, and 18. Native fallback behavior and investigation of menu localization/layout.
