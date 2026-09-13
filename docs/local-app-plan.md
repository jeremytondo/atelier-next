# Atelier: first installable macOS app

> Superseded September 13, 2026: the product is an HS2 distribution with customizable JavaScript defaults and native helpers for gaps. The standalone Swift runtime proposed below was replaced. See [the current app](../App/README.md). This document preserves the earlier architecture decision for context.

> Configuration update: the implemented app now uses TOML under `~/.config/atelier/` with explicit menu/shortcut reload. The Settings-editor portions of this original plan are superseded by [the configuration reference](../App/Resources/Configuration.md).

Proposed plan — September 13, 2026. Confirmed direction: Atelier should run independently of a separate Hammerspoon installation. This document proposes implementation; no app has been built or installed as part of this planning pass.

Implementation follow-up: the standalone local alpha now lives in [App](../App/README.md). The sections below preserve the original plan; current test results and remaining daily-use checks are recorded in the app's validation notes.

**Target outcome:** install `Atelier.app` in `/Applications`, open it from Finder, grant its required access, and use the current Spaces, Groups, and Quick Apps features throughout a normal workday. Runtime operation must not require this checkout, Xcode, Node, Python, or Hammerspoon. Replacing the app with a newer local build should preserve preferences.

## Recommendation and evidence

Build a native Swift/AppKit menu-bar app, use SwiftUI for Settings, and initially retain the existing Swift helper as a bundled child executable. Port the Hammerspoon-owned coordination, shortcuts, focus observation, and overlay into the app. Reuse the working native mechanisms and preserve the current behavior through explicit parity checks.

The relevant starting points are:

| Existing code | Use in the app |
| --- | --- |
| `Prototypes/Hammerspoon2/atelier.js` | Behavioral reference for command coordination, exact-window focus, observation, and background Fill settling. |
| `GroupStore.js`, `GroupOverlay.js`, `QuickApps.js` | Reference for ordering, overlay behavior, shortcut validation, and Quick App exclusions. |
| `Sources/SpaceControlPrototype/HS2Bridge.swift` and `QuickApps.swift` | Starting implementation for the bundled helper and Quick App operations. |
| `Sources/SpaceControlPrototype/main.swift` | Extract Space runtime, target-display resolution, and Mission Control operations from the prototype executable. |
| `NativeMenuDispatch`, `QuickAppSupport`, `SpaceControlCore` | Reuse as shared native modules. |
| `DesktopGroupsCore` and `DesktopGroupsPrototype` | Reuse suitable models, hotkey registration, and AX observation code after checking differences against the newer JS behavior. |

The JS runtime and its three feature modules total roughly 650 lines, while most Space and Quick App mechanisms already exist in Swift. The older Swift Groups controller is not a behavior-equivalent replacement: its scheduling and focus path differ from the current prototype. The current JS behavior is the reference.

Keeping the helper initially also keeps Mission Control's existing nested run-loop waits outside the app's UI process. The app should perform latency-sensitive Group focus and overlay updates directly. Share the native menu dispatcher where useful; do not put every interaction through a serialized helper request.

Two alternatives remain possible. A launcher that depends on installed HS2 offers a smaller interim step, but does not meet the proposed standalone outcome. Bundling an HS2 fork could preserve the JS, but requires owning its app lifecycle, configuration paths, identity, update behavior, and signing. The inspected 0.0.12 tree is an Xcode application rather than a ready-made Swift package. Upstream also describes HS2 and its JavaScript API as experimental. A focused native app is the recommended direction for this repository. [HS2 0.0.12 source](https://github.com/cmsj/Hammerspoon2/tree/0.0.12), [upstream status](https://github.com/cmsj/Hammerspoon2)

## Scope of the first local alpha

Carry forward Desktop switching, creation, reordering and deletion; Group creation/repair, indexed selection and cycling; the held-modifier overlay; native Fill on focus; and configurable Quick App toggles. Preserve the current shortcuts as defaults.

Add a menu-bar status item, Pause/Resume, Settings, a shortcut reference, diagnostics export, and Quit. Settings need only cover launch at login, feature toggles, and Quick Apps with an app picker, shortcut recorder, and optional size. A missing Quick App or conflicting binding should appear as an actionable configuration error while the app remains available to fix it.

Persist preferences and Quick App definitions. Keep Groups and remembered Quick App window identities session-only for this alpha, matching the prototype; state this in the app. Pause should retain in-memory Groups, while quitting/relaunching resets them. Durable workspace restoration needs a separate identity design because PIDs, window IDs, and Space IDs are not durable saved-workspace identities.

Window movement between Spaces, fullscreen overlays, always-on-top guarantees, automatic updates, App Intents, and a workspace editor remain later work. Start with Apple silicon and the current macOS 26.5.2 machine as the validated target. Declare the initial OS baseline explicitly; the prototype package's macOS 15 deployment target does not establish tested compatibility. Validate macOS 27 separately before claiming support.

## Implementation sequence

### 1. Capture the baseline and prove the installed app path

Checkpoint the current working tree before refactoring, including the uncommitted and untracked prototype work. Preserve the prototype as a runnable reference. Capture a short behavior checklist and comparable timings for focus, first Fill, repeated selection, and overlay highlight updates.

Create an app target with a stable bundle identifier, menu-bar item, Accessibility onboarding, and Quit. Establish signing and installation early. Implement a small slice that groups windows on the current Desktop, focuses an exact member, displays the held-modifier overlay, and invokes native Fill with background settling. Launch from `/Applications` with Atelier's HS2 loader stopped.

**Exit check:** this installed slice works with access attributed to Atelier and matches the prototype's responsiveness. The README's recorded 11–55 ms focus measurements are historical comparison data; remeasure both versions on the same workload before setting a performance budget. Investigate any material regression before expanding the port.

### 2. Extract the native engine and complete feature parity

Introduce an app directory and a shared native package, separate from experimental entry points. Extract reusable services without importing the old private WindowManagement transaction experiments into the shipped app. Build a dedicated bundled helper instead of depending on `.build/debug/space-control-prototype`.

Keep stdin/stdout communication initially, with typed requests/results, request IDs, a protocol version, timeouts, and an explicit startup handshake. Resolve the executable from the app bundle. The app owns its child process; EOF, Quit, and startup failure must clean it up. Do not add a privileged daemon or XPC migration to the first alpha.

Port the current policy in small slices: Groups and reconciliation, focus/Fill, overlay, Spaces, then Quick Apps. Preserve exact-target verification, focused-display/pointer targeting, background observations that do not claim the mutation lock, no duplicate Fill while settling, and rejection of overlapping mutations rather than executing stale targets later. Use bounded AX calls so an unresponsive external app does not indefinitely block Atelier's controls.

**Exit check:** the supported prototype checklist passes in the app; unavailable native Fill reports a failure rather than silently applying different window geometry. Verify the helper's permission attribution in its actual bundled launch context.

### 3. Make configuration and everyday controls usable

Implement the small Settings surface and versioned preference storage. Use `UserDefaults` for simple preferences and Application Support for structured configuration; keep logs under Library/Logs. App resources remain read-only.

Migrate the known prototype Quick App definitions once, preserving app identity, shortcut, and size. Do not execute arbitrary user JavaScript in a migration parser. If the existing file contains computed configuration, provide a short manual entry path and report what was imported. Preserve the source file and back up any app configuration before schema migration.

Add launch at login through `SMAppService.mainApp`, initially off, and display its actual registration/authorization state. [Apple's service management API](https://developer.apple.com/documentation/servicemanagement/smappservice)

During first-run handoff, stop only Atelier's prototype loader and verify its helper exits before registering app shortcuts. Preserve unrelated Hammerspoon configuration. Prevent a second Atelier instance and provide an understandable conflict state if the prototype still owns the shared Space-operation lock. Document how to quit Atelier and return to the prototype.

**Exit check:** daily configuration, pausing, resuming, and quitting all work without editing a JS file or using a terminal. Preferences survive replacing and relaunching the app.

### 4. Harden lifecycle and make failures diagnosable

Use explicit states for starting, running, paused, permission missing, and engine failure. On helper timeout or crash, mark in-flight mutations as having an unknown outcome, release the app's bindings, and offer a controlled restart. Inspect fresh topology before resuming; never automatically replay a timed-out create/delete/reorder/toggle.

Handle permission revocation, sleep/wake, display changes, Dock restart, and applications opening/closing. Probe required private symbols and AX capabilities; disable dependent features with a useful explanation when their prerequisites are unavailable. Pause/Quit should stop observers and timers, hide the overlay, cancel pending work, and restore temporary native shortcut changes.

Normal cleanup cannot run after a forced kill. Record enough information to diagnose and reconcile Atelier's temporary shortcut changes on the next launch, and verify the actual crash behavior before claiming restoration. Preserve user changes made since the recorded operation.

Treat Quick App All Desktops assignment separately: the current Dock fallback can persist. Explain this when enabling a Quick App and provide instructions to undo it via Dock → Options → Assign To → None. Removing a Quick App or deleting Atelier must not falsely claim to have reverted that assignment.

Export a bounded local diagnostics bundle containing app/OS versions, capability and permission state, recent errors, operation latency, and dropped-operation counts. Omit window titles by default; let the user deliberately include them for a focused investigation. Measure idle CPU/memory and verify that repeated pause/resume does not accumulate observers, timers, or helper processes.

**Exit check:** the failure/recovery checklist passes, errors remain actionable, and a diagnostics export is sufficient to investigate daily-use problems.

### 5. Produce a repeatable local release

Add a repeatable release workflow that builds/tests, bundles resources and the helper, assigns version/build numbers, signs nested executables and the outer app, and emits an installable app plus a ZIP. Use the same bundle identity and signing identity across local updates where available; test permission retention rather than assuming it.

For this machine, use local development signing with the available identity. An ad-hoc fallback must be documented as local-only and may require renewing Accessibility authorization after replacement. Check available signing setup during milestone 1; external distribution credentials should not block the local alpha.

Build outside the App Sandbox for the current cross-application behavior, and exercise the release configuration with Hardened Runtime early. For builds shared beyond the local development machine, add Developer ID signing, notarization, and ticket stapling. Apple documents these as distinct distribution requirements; a locally installed development build does not validate that workflow. [Apple's notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

A DMG can follow when useful; a drag-installable `.app` in a ZIP is sufficient for the first alpha. Include a version label, short release notes, and replacement/removal instructions. Verify resources resolve without repository paths and ordinary operation works with Hammerspoon closed and the checkout temporarily unavailable.

**Exit check:** install, launch, quit, replace with a newer build, and remove the app using normal Finder workflows; preferences survive replacement and removal leaves no running helper or active login item after the documented cleanup.

### 6. Run a controlled daily-use trial

First run a smoke checklist on disposable Desktops and saved test documents. Then use the app for several normal workdays, recording the build and exporting diagnostics when something fails.

| Area | Checks |
| --- | --- |
| Installation/lifecycle | Fresh permission grant, denied/revoked permission, login launch, duplicate launch, pause/resume, quit, update, rollback. |
| Groups/Fill | Multiple windows from one app; close/minimize/hide/manual resize; immediate highlight; rapid repeated selection; unsupported Fill; no focus stealing from Atelier UI. |
| Spaces | Switch/create/reorder/delete; correct IDs and display; refuse deleting the final Desktop; verify windows survive deletion; fullscreen Spaces excluded from numbering; rapid physical shortcuts during native dispatch. |
| Quick Apps | Calculator, an installed resizable app with configured size, and 1Password when installed; hidden/minimized/closed states; exact focus restoration; no unwanted Desktop switch; exclusion from Groups. |
| Environment/recovery | Two displays including alternate arrangements, reconnect, sleep/wake, Dock restart, helper termination, and recovery from an interrupted mutation. |
| Responsiveness | Compare focus/overlay/Fill timings to the prototype, inspect idle CPU/memory, and watch for resource growth during the trial. |

Keep model/coordination tests focused on behavior: membership/order, stale identities and targets, Quick App exclusions/conflicts, asynchronous Fill, cancellation, and unknown mutation outcomes. Port the relevant JS scenarios to Swift and run the existing native tests after extraction. Unit tests complement the installed-app checks; they cannot establish that macOS actually changed focus or Spaces.

**Alpha acceptance:** the app runs independently from `/Applications`, carries the supported workflow through a normal workday, preserves preferences across updates, pauses/quits cleanly, and makes failures observable and recoverable. Expand feature scope only after addressing defects found in this trial.

## Planning validation

Reviewed the current HS2 runtime, native helper, older Swift Groups implementation, shared modules, and project research. Confirmed the development machine is Apple silicon on macOS 26.5.2 and the installed HS2 is the documented build 133. `node --test Prototypes/Hammerspoon2/*.test.js` passed all 17 tests. The XcodeBuildMCP CLI is available. No native builds, live Desktop mutations, permission changes, installations, or trial testing were performed for this plan.
