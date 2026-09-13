# Hammerspoon 2 prototype (ATE-35)

HS2 owns shortcuts, Group ordering, focus observation, and Fill policy. A native
helper supplies real macOS Space topology, quick-app window operations, and Desktop operations. Sending windows between
Spaces and move-and-follow are currently disabled; WhichSpace is no longer required.
The implementation targets **HS2 release 0.0.12** (bundle 1.2,
build 133); its watcher API differs from newer development sources.

The plan and measured findings live in [ATE-35](https://linear.app/elevenideas/issue/ATE-35/prototype-hammerspoon-2-for-native-spaces-and-groups).

## Run

Install Hammerspoon 2 in Applications and grant the access its onboarding requests. From the repository root:

```sh
xcodebuildmcp swift-package build --package-path "$PWD/Prototypes/NativeWindowTilingPOC"
python3 Prototypes/Hammerspoon2/setup.py install
```

Choose **Reload Config** in HS2's menu. The setup script backs up the existing
config once, preserves its contents, and adds a marked loader block. HS2 loads
the JavaScript directly from this checkout. Group state is session-only and
resets on config reload.

```sh
# Read-only probe through HS2:
python3 Prototypes/Hammerspoon2/command.py '{"command":"probe"}'
# Stop/restart only the Atelier prototype:
python3 Prototypes/Hammerspoon2/command.py '{"command":"stop"}'
python3 Prototypes/Hammerspoon2/command.py '{"command":"start"}'
# Remove the loader, then reload HS2:
python3 Prototypes/Hammerspoon2/setup.py uninstall
```

The native helper also accepts JSON lines over stdin via
`./space-control --hs2-bridge`. It registers no hotkeys. Closing stdin or stopping
the process releases its lock and restores temporary native shortcut enables.

## Quick apps

`setup.py install` creates **`~/.config/hammerspoon2/quickapps.js`** once and wires it
into the loader. Edit that file and choose **Reload Config** in HS2:

```js
module.exports = [
  { app: "Calculator", shortcut: "ctrl-option-c" },
  { app: "1Password", shortcut: "ctrl-option-p", size: { width: 900, height: 650 } },
];
```

The installed starter enables Calculator and leaves 1Password commented out until
it is installed. App names, bundle IDs, and absolute `.app` paths are accepted.
Only `app` and `shortcut` are required. Optional `size` is in points; otherwise the
window keeps its size, clamped to the usable display. Apps can enforce a minimum
size. `command`/`cmd`, `option`/`alt`, `control`/`ctrl`, and `shift` are supported;
use names such as `space`, `return`, `left-bracket`, or `minus` for special keys.

Press the shortcut to launch/reopen, unhide, center, and focus the app on the display
captured before activation (focused window's display, pointer fallback). Press it
while the app is frontmost to hide the whole app and restore the remembered window
if it still exists on the original, still-active Desktop. If the app is visible but
unfocused, the shortcut brings it forward. Minimized target windows are restored.
Standard windows and nonmodal app dialogs such as Calculator are supported; sheets,
modal dialogs, fullscreen windows, and fullscreen/Split View target Spaces are excluded.

All Desktops assignment is applied automatically and verified. The native Dock
fallback can briefly show a menu and persists like a manual assignment. Remove it
using **Dock → Options → Assign To → None**; removing an entry or stopping Atelier
does not reset that assignment. A shown quick app remains available across ordinary
Desktops until hidden. This is a centered foreground window, with no persistent
always-on-top guarantee. Quick apps are excluded from Groups and Fill-on-focus.

Setup preserves an existing `quickapps.js`. For an existing custom loader, pass
`quickApps: require("/absolute/path/to/quickapps.js")` to the Atelier factory. An
omitted list defaults to empty. Invalid entries, missing apps, duplicate app identities,
duplicate shortcuts, and detected shortcut conflicts stop startup with an error;
fix the config and reload. macOS may not expose every shortcut claimed by another app.

```sh
python3 Prototypes/Hammerspoon2/command.py '{"command":"quickApps"}'
python3 Prototypes/Hammerspoon2/command.py '{"command":"quickApp","app":"Calculator"}'
```

The Console equivalents are `atelier.quickApps()` and `atelier.quickApp("Calculator")`.
Toggle state is session-only. Overlapping operations return `busy`. Errors report
failed assignment, Desktop changes, placement, or focus instead of claiming success;
an app may already be visible when a later validation fails.

Validated on September 13, 2026 with the installed HS2 0.0.12: Calculator summoned
centered on each of two ordinary Desktops without switching Spaces, hid on the next
toggle, restored the previous exact window, recovered minimized and closed windows,
and remained excluded from an active Group. The registered Control–Option–C shortcut
was exercised with synthetic keyboard events. Multi-display placement, configured
sizes in resizable apps, and 1Password remain manual checks; 1Password was not found
on the test Mac. Fullscreen overlays are unsupported.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| Option+1…9 / 0 | Desktop 1…10 on the focused window's display; pointer fallback |
| Option+\` | Create and enter a Desktop |
| Ctrl+Option+Left / Right | Reorder the current native Desktop |
| Ctrl+Option+Delete | Delete current Desktop; refuse the last Desktop |
| Cmd+Option+G | Create/repair the current Desktop's Group |
| Hold Cmd+Option | Show the current Group's window list at the bottom right |
| Cmd+Option+1…9 / 0 | Focus Group member 1…10 and Fill if needed |
| Cmd+Option+[ / ] | Previous/next Group member |

The floating list shows app names in Group order and highlights the focused window.
Windows from the same app also show their titles. Release either modifier to hide
it; adding Control or Shift also hides it. It appears only on a grouped Desktop,
on the same display used by the Group shortcuts, above the Dock. The panel passes
clicks through and does not take keyboard focus. The highlight redraws as soon as
focus lands, before Fill runs. The tenth member is labeled `0`;
members beyond ten are dimly numbered and reachable with `[ / ]`. Set
`groupOverlay: false` in the loader options to disable it.

After updating the prototype, choose **Reload Config** in HS2 and group the desired
Desktop again with **Cmd+Option+G** (Group state resets on config reload).

Creation, reorder, and deletion use Mission Control internally and close it
after success. Switching retains the normal native animation. Numbering excludes
fullscreen Spaces; the native symbolic route supports at most 16 global Desktops.
Overlapping prototype operations return `busy` rather than queueing stale targets.
The background observe pass does not take that lock. It runs every second and on
window focus, creation, destruction, minimize, and resize events, keeps Group
membership current, and Fills a newly focused member. Shortcuts keep working while
it runs, and it skips its Fill if a switch moved focus meanwhile. `status`
metrics record each dropped operation as `dropped:<name>` with `blockedBy`.
Space bindings are temporarily disabled during native shortcut dispatch to avoid
recursion; rapid physical input during that interval still needs manual evaluation.

## Fill comparison and diagnostics

Default `native-js` invokes Apple's Fill menu action through HS2 Accessibility.
`native-helper` invokes the same action through the existing native dispatcher.
`padded` resizes to the usable screen frame inset by eight points. Modes are
explicit; there is no silent fallback between native Fill and geometry resizing.

A switch no longer waits for Fill. It presses Fill, releases the operation lock,
and confirms the result in the background, so the next shortcut runs at once. The
background check caches a window's filled frame once the frame stops changing and
no AX move or resize event has arrived for 100 ms. If nothing moves within 300 ms,
as with an already-filled window, it caches the unchanged frame. A window being
checked is not filled again until the check finishes. A Fill that never settles
or is rejected reports an error as a notification. `status` metrics record each
Fill's `pressMs`, whether the frame `changed`, `firstChangeMs`, the number of
`axEvents` seen, and total `roundTripMs`. The loader can override the thresholds
with `fillQuietMs` and `fillGraceMs`.

```sh
python3 Prototypes/Hammerspoon2/command.py '{"command":"fillMode","mode":"padded"}'
python3 Prototypes/Hammerspoon2/command.py '{"command":"group"}'
python3 Prototypes/Hammerspoon2/command.py '{"command":"status"}'
python3 Prototypes/Hammerspoon2/command.py '{"command":"overlayStatus"}'
```

```sh
python3 Prototypes/Hammerspoon2/command.py '{"command":"benchFocus","rounds":2}'
```

`benchFocus` cycles the current Group with pure-HS2 focus strategies (no helper
call) and writes `.runtime/focus-bench.json` plus a progress log. Measured on
September 13, 2026 with HS2 0.0.12 on a four-window Group: `HSWindow.focus()`,
`raise()` + `focus()`, and `HSApplication.activate()` all returned true without
changing focus (0 of 24 verified). Setting `AXFrontmost` on the application
element and `AXMain` + `AXRaise` on the window through `hs.ax` focused the exact
window in 21 to 64 ms including window lookup (7 of 7 verified). The released
build exposes the AX setter as `setAttributeValueValue`. Timers created inside an
awaiting function must be kept reachable from a global, or HS2 collects them
before they fire.

Group switches now use that accessibility route: lookup through the member's app,
then `AXFrontmost`, `AXMain`, and `AXRaise`, verified for up to 500 ms. There is
deliberately no native fallback, because a fallback would hide whether HS2 alone
can focus the window. A switch that does not verify fails with an error naming
the app. `status` metrics record each switch as `hsFocus:ax`, `hsFocus:already`,
or `hsFocus:failed`, with `lookupMs`, total `roundTripMs`, and a timestamp.
`overlayStatus` lists recent timestamped overlay highlight changes for comparing
overlay lag against focus.

Measured on September 13, 2026 after the change, over twelve `select` switches
across Chrome, Ghostty, and a Gmail web app: every switch focused through the
accessibility route with no helper fallback. Focus took 11 to 55 ms, median 39,
with window lookup under 10 ms. The whole switch action took a median of 52 ms,
down from about 430 ms before. The first switch to an unfilled member still
spends about 500 ms in Fill's settle wait.

The HS2 Console also exposes `atelier.probe()`, `atelier.group()`,
`atelier.select(2)`, `atelier.space("switch", {number: 3})`,
`atelier.reorderMember(-1)`, and `atelier.stop()`.
Methods return promises; attach `.then(...)` / `.catch(...)` when inspecting results.

The fixed-command CLI uses a private `.runtime` directory because the released
HS2 XPC CLI did not connect on the test Mac. It does not evaluate client-supplied
JavaScript. Inspect the Console if a command times out; a timeout is not proof
that a native mutation did not happen. Runtime diagnostic files can contain
window titles and are ignored by Git.

The overlay uses input-event flags: on the tested HS2 release, `currentModifiers()`
returned an empty array even while physical Cmd+Option events carried both flags.
Canvas colors use explicit RGB components because HS2 does not implement the v1
`white` color shorthand. `overlayStatus` reports whether the overlay is enabled,
whether its modifier chord is active, and whether its canvas is showing.

## Checks

```sh
node --test Prototypes/Hammerspoon2/*.test.js
xcodebuildmcp swift-package test --package-path "$PWD/Prototypes/NativeWindowTilingPOC"
```

For live testing, create disposable Desktops and saved test documents first.
Verify actual Space IDs, ordering, focus, and window membership after operations.
Close only test windows and remove only test Desktops when finished.
