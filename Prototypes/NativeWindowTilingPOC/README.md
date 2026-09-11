# Native window tiling proof of concept

ATE-14 builds on this package with a long-running
[Desktop Groups prototype](DESKTOP-GROUPS.md). The shared `NativeMenuDispatch`
target now supplies the semantic Accessibility dispatcher to both executables.

ATE-13 now has a working native tiling route: find the foreground app's native
Window menu command by its Accessibility identifier and invoke `AXPress`.
The owning app performs macOS tiling; the tester does not synthesize shortcuts
or resize windows through Accessibility frame assignments.

Four TextEdit placements have native WindowManager log corroboration. After
trying the focused-window tester, the user reported that it “actually works
pretty well.” This supports continuing with semantic menu invocation, while
compatibility across apps, repeated-use reliability, and desktop-wide layouts
still need systematic testing. Native restoration differed by up to one point
per frame component in the fixture tests. See the
[validation evidence](Evidence/2026-09-10-menu-validation/README.md).

Start with [REVIEW.md](REVIEW.md) for the evidence audit, implementation
recommendation, and research into Loop, BetterTouchTool, and other applications.
[FINDINGS.md](FINDINGS.md) preserves the original experiments, whose keyboard
and foreign-client failures were initially overgeneralized.

## Run it

### Try it on your own windows

Build from the repository root, then run in Ghostty:

```sh
swift build --package-path Prototypes/NativeWindowTilingPOC
./tile-window left
```

Switch to your target window during the five-second countdown. The tester
invokes that window's native menu command and leaves the result visible. It
does not launch or close applications. Run `./tile-window untile` and switch
back to the same window to request Return to Previous Size.

Other placements include `right`, `top`, `bottom`, `top-left`, `top-right`,
`bottom-left`, `bottom-right`, `fill`, and `center`. Control-C cancels the countdown.
Missing or disabled native commands produce an error with no geometry fallback.
The tester reports discovery/dispatch time, excluding the countdown and native
animation; it aborts if focus changes while discovering the command.

Rebuild after source changes. Grant Accessibility permission to the responsible
application in System Settings > Privacy & Security > Accessibility. For tests
launched from Ghostty, that is Ghostty; the agent-launched tests on this Mac
were attributed to its `node` runtime instead. This is a manual tester;
global hotkeys are not installed.

The equivalent executable invocation is
`native-window-tiling-poc left --focused-window`.

### Disposable fixtures

The earlier private-framework experiments are retained as controls. Their
framework and selectors are resolved at runtime, but the private Objective-C
bridge does not validate every method or signature and may fail after an OS
update. The focused-window tester does not initialize that SkyLight bridge.

From this directory:

```sh
swift run native-window-tiling-poc left
```

Other commands include `right`, `fill`, `top`, `bottom`, `top-left`, `top-right`, `bottom-left`, `bottom-right`, `center`, and `untile`.

To check private API availability without opening a window:

```sh
swift run native-window-tiling-poc --probe
```

To open, tile, print the before/after WindowServer bounds, and exit automatically:

```sh
swift run native-window-tiling-poc left --smoke-test
```

To test the direct private `WindowManagement.framework` transaction across a
process boundary, without menu actions or Accessibility frame changes:

```sh
swift run native-window-tiling-poc left --cross-process-smoke-test
```

This launches a disposable fixture window in a second process, submits a native
transaction using its private WindowManagement identifier, reports its bounds,
and closes the fixture.

To send the standard system tiling shortcut directly to the fixture process,
without discovering or invoking a menu item:

```sh
swift run native-window-tiling-poc left --keyboard-cross-process-smoke-test
```

Synthetic input sent to another process requires Accessibility permission. To
ask macOS to open the permission UI, run once with:

```sh
swift run native-window-tiling-poc left --keyboard-cross-process-smoke-test --request-accessibility
```

Approve the responsible application in Privacy & Security > Accessibility and
rerun the first command. The test reports Accessibility and event-posting
authorization along with before/after WindowServer bounds.

To repeat the stronger control against a standard TextEdit document window:

```sh
swift run native-window-tiling-poc left --standard-app-keyboard-smoke-test
```

To test the native menu route identified in the research:

```sh
swift run native-window-tiling-poc left --standard-app-menu-smoke-test
```

This requires Accessibility permission and TextEdit to be closed. It opens a
temporary document, finds the native action by `AXIdentifier` (not its localized
title), invokes `AXPress`, waits for stable bounds, then invokes Return to Previous
Size and checks restoration. It does not open menus, synthesize keys, or assign
window frames. `top-left`, `right`, and `fill` can also be supplied. Do not use
`untile` as the placement because the probe runs it as the restoration control.

If permission is missing, the probe stops before opening TextEdit. Use the
existing `--request-accessibility` option to request the macOS permission UI,
approve the responsible executable/application, and rerun. Rebuilding or changing
the launch context may require checking authorization again.

After enabling Accessibility for the responsible `node` runtime, **native
cross-process tiling was verified in TextEdit** for left, right, top-left, and
fill. All four runs produced the corresponding WindowManager native-state log
and an untile transition, with unchanged pointer coordinates. Restoration
differed by up to one point per frame component; the probe reports exact equality,
one-point tolerance, and deltas separately. See the
[validation evidence](Evidence/2026-09-10-menu-validation/README.md).

The local control case can also bypass the `NSWindow` tiling selector and call a
separately initialized private AppKit coordinator directly:

```sh
swift run native-window-tiling-poc left --coordinator-smoke-test --smoke-test
```

Tested against macOS 26.5.2 (build 25F84) on Apple silicon.
