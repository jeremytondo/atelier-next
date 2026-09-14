# ATE-40: direct activation works; Dock registration remains separate

New evidence on macOS 26.5.2 (25F84), SIP enabled, September 14, 2026.
This supplements the earlier findings without changing their historical results.

The existing owned Space **168** can become current through WMBridge, show an
ordinary test window, and accept keyboard input saved to that window's file.
It still does not appear in Mission Control. An independent read from Dock now
reports **two** user Desktops while WindowServer reports **three**.

## External implementation details that led to the trials

- Native Space Kit uses show-target, hide-display-siblings, then set-current.
  Its activation probe checks a fixture in the compositor. Its lifecycle probe
  confirms a new type-0 census entry; that probe does not inspect Mission Control.
  We reproduced activation and typing locally, independently of native entry.
  [Pinned implementation](https://github.com/Fjx-dylanZ/native-space-kit/blob/01b7e49718d500ed08add3e95533e2b9b41b2561/src/native_space_kit.m#L414),
  [pinned probes](https://github.com/Fjx-dylanZ/native-space-kit/blob/01b7e49718d500ed08add3e95533e2b9b41b2561/probes/smoke.py#L241).
- Yabai's scripting addition creates a Dock `ManagedSpace` object and invokes
  Dock's internal add function. This is additional coordination beyond allocating
  a WindowServer Space. We did not inject into Dock or run Yabai.
  [Creation path](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m).
- The older Hammerspoon extension's Lua wrapper restarts Dock by default after
  its native create call. That is an explicit extra step, not evidence that its
  low-level create call alone registers a Desktop. No Dock restart was attempted.
  [Historical wrapper](https://github.com/asmagill/hs._asm.undocumented.spaces/blob/master/init.lua#L255).
- Native Space Kit's open PR 2 reports additional fixture interaction on 27 RC,
  but explicitly says SIP was already disabled on that contributor's host.
  It does not extend the project's SIP-enabled verification.
  [Contribution report](https://github.com/Fjx-dylanZ/native-space-kit/pull/2).

## Bounded local trials

All trials reused returned ID 168, UUID
`432996B4-BAD7-410B-A47E-18950F94CFB1`, from the original creation journal.
No new Space was created or destroyed. The starting and restored topology was
`[3, 176, 168]`, current **176**, display
`BF1BDA7D-2A5B-41FB-933D-405802D73ED3`. Desktop 176 was the user's native control.

Raw evidence is under `.build/ate-40-manual/trial-36rXDA/`; each named trial has
exclusive intent, dispatch, and result files. The activation and reorder trials
also have a restoration intent. Space ownership and native UUID were checked
before dispatch. All completed trials reported the starting topology restored.

| Trial subdirectory | Operation and observation |
| --- | --- |
| `place-current` | Explicitly place 168 at its existing final index. Census unchanged; Mission Control two thumbnails before and after. |
| `reorder-roundtrip` | Move 168 to zero-based index 1. Census became `[3,168,176]`; Mission Control remained at two. Restored `[3,176,168]`. |
| `activate-roundtrip` | Show 168, hide 3/176, set current to 168. Current changed; Mission Control remained at two. Initial typing result invalidated by the harness defect below. Restored current 176. |
| `typing-control-original` | Unmodified typing fixture also failed on normal Desktop 176, demonstrating the initial typing failure was not specific to 168. |
| `typing-control-pumped` | After fixing AppKit event delivery, typed/saved successfully on 176 in approximately 136 ms from fixture start. |
| `activate-pumped` | Repeated activation with the corrected fixture: current 168, fixture on screen, AppKit `isOnActiveSpace=true`, typed/saved successfully in approximately 150 ms from fixture start. Mission Control remained at two. Closed fixture and restored 176. |
| `refresh-display` | Refused before dispatch because the single AppKit screen belongs to a mirror group. |
| `refresh-empty` | Empty CoreGraphics configuration transaction succeeded, emitted no display callbacks, and left Mission Control at two. Current mode/bounds unchanged. |
| `refresh-mirror-mode` | Reapplied the mirror source's exact existing mode. Succeeded, emitted no display callbacks, and left Mission Control at two. Both mode IDs, mirroring relationship, and source bounds remained unchanged. |

The positive 168 typing fixture was window **3767**, with sole saved file
`activate-pumped/typing-fixture-51513B25-5D41-42F1-BB9A-E612DF4AA4FC.txt`.
The exact focused window and Space membership were checked before input.
Its text contains `ATE40 verified typing`; the owned window closed on return.
These timings exclude activation, native navigation, and creation, so they are
not keyboard-to-new-Desktop latency measurements. These trials deliberately
opened Mission Control for observation and are not zero-flash tests.

### Typing harness correction

The synchronous fixture originally ran a nested Foundation run loop while
waiting for keyboard input. It did not pull and deliver AppKit's queued events.
Adding `NSApplication.nextEvent` / `sendEvent` made the normal-Desktop control
pass, then the owned-Space trial pass. The fixture now gives input its own
deadline and checks presence in `CGWindowList`'s on-screen query. The earlier
`typed=false` values are retained in their raw journals but are not macOS failure
evidence. September 13's typing attempts refused before sending input because
native entry failed; this correction does not establish that native entry worked.

## Independent Dock count and display topology

`diagnose-1789392693948-521304f8-a6d6-453c-8832-8c886f885b64.json` records:

- `CoreDockGetWorkspacesCount`: status 0, legacy grid dimensions 1 and 2, count 2.
- WindowServer: ordinary IDs `[3,176,168]`, current 176.
- Saved configuration: the same three IDs.
- `SpaceCopyOwners`: empty arrays for all three IDs; no distinguishing owner.
- AppKit: one screen, Jump Desktop Display 1, numeric display 27.
- CoreGraphics: display 27 is the active mirror source, mode 90; physical
  display 3 mirrors 27, mode 55. Both report logical bounds 1600×1000.

The count read was checked against local arm64e HIServices disassembly:
`CoreDockGetWorkspacesCount` at `0x187BA700C` accepts two 32-bit output pointers
and calls `DSGetWorkspacesCountPreference`. Dock's handler calls `allUserSpaces`
at `0x1000976C0` and `count` at `0x1000976D0`. It is an independent live Dock
query, not another spelling of `SLSCopyManagedDisplaySpaces`. The nearby setter,
`CoreDockSetWorkspacesCount` at `0x187BA7004`, only returns -50 on this build;
it is not an untested creation opportunity. The setter was not invoked.

## Remaining lead: Dock's display-reconfiguration handler

Local Dock arm64e disassembly links an actual display callback to
`handleDisplayReconfig` at `0x10011BFA0`. Its method at `0x1001EF310` invokes
helper `0x1001EEA20`, which reads WindowServer's census at `0x1001EECCC`.
Comparison helper `0x1001EEE38` compares display IDs, current IDs, per-display
Space counts, and ordered Space IDs with Dock's model. A mismatch can call the
model-rebuild helper `0x1001E4D0C` at `0x1001EED8C`.

This is a concrete repair hypothesis, not a proven repair. Both unchanged
configuration trials emitted no callbacks, so they did not exercise this path.
A manual Jump Desktop resolution change and restoration was requested to test
the handler without guessing a private notification payload. Its outcome is
pending. A positive result would explain a missing synchronization step; it
would still need a creation-time trigger satisfying the no-flash requirement.

The mirrored remote display is another difference from the external reports.
It is not established as the cause. A stable physical/non-mirrored comparison
and a named newer OS build remain useful controls.

`mise run wmbridge:test` passed 5 Swift and 13 Node tests. Native builds/runs used
XcodeBuildMCP. No production creation defaults or security settings changed.
Owned Space 168 remains available for the requested manual display-change test;
the user-created Desktop 176 remains intact.
