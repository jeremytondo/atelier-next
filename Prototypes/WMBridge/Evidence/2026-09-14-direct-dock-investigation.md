# ATE-40: direct Dock synchronization investigation

This follows the [latency work](2026-09-14-creation-latency.md). The objective was
to find an ordinary-process route that updates Dock's Desktop model and numbered
shortcut registrations without a display pulse. **No replacement was established.**
The working create-and-enter command still uses the temporary virtual display.
New evidence narrows the alternatives; it does not prove that every possible
route has been exhausted or that other macOS builds require this workaround.

## Local static findings

Inspection used this Mac's arm64e Dock, UUID
`5DF5CC12-1875-3DEA-9DF7-48A3F8BEF94D`, on macOS 26.5.2 (25F84).
Disassembly, Objective-C metadata, strings, and raw string bytes were read with
`dyld_info`. No code was loaded into Dock and no service requests were sent.
Private raw evidence is `.build/ate-40-manual/direct-dock-iEfG34/static-trace.json`.

| Candidate | Finding on this build |
| --- | --- |
| Native Desktop add | Helper `0x1001F07D8` has direct callers from the Mission Control UI (`0x10022ABB4`) and Dock's PPT service (`0x10027EB10`). The PPT caller uses the main display. Finding an internal function is not an external calling interface. |
| PPT service | Its connection handler checks `com.apple.private.dock.ppt`, then checks the peer's code-signing identifier against `com.apple.DockPPT`. Failure cancels the connection at `0x10027E618`. This is not an ordinary Atelier client path. No PPT messaging or identity/entitlement workaround was attempted. |
| Spaces service | Its handler checks `com.apple.private.dock.spaces`, then accepts code identities for `com.apple.SpacesTouchBarAgent` or `com.apple.wallpaper.agent`. This also is not an ordinary Atelier client path. |
| Numbered shortcuts | The direct branch inventory still reaches `0x100007870` only through initialization or the thunk used by native add/remove. It reads Dock's `allUserSpaces` count and registers/removes the corresponding hotkeys on Dock's own connection. |
| Model rebuild | In addition to initialization and display reconfiguration, two rebuild call sites are guarded by Dock-local deferred state. The display handler sets the deferred rebuild flag at `0x1001EED04`. Merely finishing a transition is not evidence that an omitted Desktop will be reconciled. |
| Legacy workspace settings | `CoreDockSetWorkspacesCount` and `CoreDockSetWorkspacesEnabled` immediately return `-50`. **`CoreDockSetWorkspacesKeyBindings` immediately returns `0` without any work** (`0x187BA7080`–`0x187BA7084`). Its apparent success cannot repair registration. These stubs were not invoked. |

The entitlement checks above were followed beyond their string constants:
`0x1003112F4` reads the connection's audit token, creates a `SecTask`, and checks
each named entitlement through `SecTaskCopyValueForEntitlement`. The subsequent
identity checks read `kSecCodeInfoIdentifier`. This is static evidence of receiver
validation, not a live rejection experiment or a claim about every service in Dock.
The branch inventory covers direct branches to the identified helpers; it is not
a proof excluding all indirect dispatch paths.

## Additional external implementations

Two additional primary-source implementations did not supply the missing repair:

- [bobrwm's SkyLight adapter](https://github.com/bobrwm/bobrwm/blob/572265d67846a3e7e3f1bdcf3440b0b9044ce63c/src/skylight.zig)
  uses the same options-0 bridged creation and returns the nonzero ID. That wrapper
  does not verify Dock registration or provide a refresh. Its separate gesture
  navigation code does not establish creation coexistence.
- [WindowKit's WindowStash](https://github.com/ejbills/WindowKit/blob/996a40bc418bdf6c477c86e16b12a07f1af48b56/Sources/WindowKit/SystemBridge/WindowStash.swift)
  deliberately creates a hidden storage Space with options 1 and an absolute
  level. Its stated goal is exclusion from Mission Control, so it does not solve
  ordinary Desktop creation. That sequence was not adopted or run.

These are source observations, not Atelier validation of those projects. The
earlier KiwiDesk/Native Space Kit coverage gaps remain; further wrappers using
the same allocation operation do not close them.

## Read-only Accessibility inspection and guard improvement

The new command is reproducible without opening Mission Control:

```sh
mise run wmbridge:run -- dock-inspect
```

It reads Dock's current AXChildren hierarchy, role/identifier metadata, exposed
action names, parameterized attribute names, and independent Desktop count.
It invokes no actions or parameterized reads. App/window titles are not recorded.
An unavailable query is preserved as uncertainty, not an empty action list proof.

`dock-inspect-final.json` traversed 43 elements in approximately 26 ms with a
complete child hierarchy: the Dock application, its list, and 41 Dock items.
There was no Mission Control hierarchy or Desktop-plus button among these
elements. The action queries succeeded for the Dock items; the application and
list returned AX error `-25200`, so the report correctly has `complete=false`.
This bounds the negative observation to the exposed hierarchy and successful
queries; it does not prove that an unexposed action cannot exist.
Dock remained PID 424, count 3; the native census remained `[3,256,244]`, current 3.

Code review also found that the old Mission Control visibility walk discarded
AX errors and silently stopped at traversal limits. That could classify an
unavailable or incomplete hierarchy as a closed overview. The ready flow now
shares the bounded hierarchy reader with this probe. A failed required read,
unexpected child list, empty application root, excessive depth/node count, or
deadline throws before a closed-overview result can be used. Missing optional
attributes remain distinct from failed queries. Action-name queries are diagnostic
only and are not added to the creation path.

## Recorded validation and cleanup

The existing 7 Swift and 16 Node checks passed through `mise run wmbridge:test`.
They cover the existing creation/lifecycle seams; no injected AX-failure test was
added. The guard change was also exercised by one recorded real create-and-enter
trial, through XcodeBuildMCP and the existing mise recording task.

The fresh baseline was `[3,256,244]`, current 3, one AppKit screen on Jump Desktop
display 27, logical 1600×1000, pixel 3200×2000, mode 90. Physical display 3 remained
mirrored to 27 at mode 55. SIP was fully enabled and no Atelier app was running.

`recorded/creation/` created Desktop **312**, UUID
`BB4B72DD-51EA-4102-8F3B-82CD6D93CD26`, and placed it after 3. Native timings were
879 ms to Dock readiness, 1,467 ms to verified adjacent entry, and 1,656 ms through
the final observation/typing result. The fixture typed and saved successfully in
184 ms from fixture start; window 4838 closed. Dock count was 4. The full setup
observation lasted 1,156 ms, with complete queries and no new setup window.
Pointer and original application window bounds matched through refresh, and
original display modes, online IDs, and mirroring were restored.

Finder was foreground both before and after refresh, but both snapshots lacked
a known focused window. The `focusUnchangedThroughRefresh=false` result is
inconclusive focus evidence. This trial is not a new focus-preservation pass,
numbered-shortcut repair, or speed improvement measurement.

All 54 video samples were reviewed across both contact sheets. They show the
ordinary native slide and the typing fixture; no Mission Control overview or
display setup dialog was observed. The movie is 12 seconds long, nominal 8.733
fps, last sample 5.283 seconds, maximum sample gap 2.750 seconds. Sparse recording
limits any absence-of-flash claim.

Native numbered return to original Desktop 3 succeeded. Cleanup removed only
owned Desktop 312 after the occupancy guard passed. Its final report has Dock
count 3, exact original IDs/UUIDs/order `[3,256,244]`, current 3, and restored display
configuration. There are no remaining resources from this follow-up.

SHA-256 anchors relative to the private evidence parent's `recorded/` directory:

- `create.mov`: `8f5feeb23e902d29c05b21b416cd68d0235479a0788b3698a42499384427bb82`
- `creation/ready-result.json`: `59fa39d7e0b67e810659743983da936a08cd0e95a493462a9d4f3fb237c64975`
- `creation/cleanup-ready-result.json`: `0fb83f156ab22c2bb018e2aa6d9bd431d8eec1c0d57271ef416e6c1c4db668de`

## Next discriminating comparison

Retain the working prototype, with numbered registration explicitly incomplete.
Compare raw creation against the repaired flow on an ordinary nonmirrored display
and a newer named macOS build, measuring Dock's count independently of WindowServer
and testing the newly added highest numbered shortcut. Those configurations were
not tested in this follow-up. A positive result there would justify a conditional
refresh policy; it would not retroactively establish support on this build/setup.
The direct services and legacy stubs inspected here do not justify another local
mutation trial or a production integration recommendation.
