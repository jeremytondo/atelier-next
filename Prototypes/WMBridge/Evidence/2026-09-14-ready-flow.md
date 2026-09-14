# ATE-40: working creation, Dock refresh, and native adjacent entry

New evidence on macOS 26.5.2 (25F84), arm64, SIP enabled, September 14, 2026.
This supplements [the manual resolution-change result](2026-09-14-display-refresh-confirmed.md).

The prototype now demonstrates an end-to-end create/enter/type flow without
opening Mission Control or changing the original display resolution. It combines
WMBridge creation with a short-lived private virtual display and native adjacent
navigation. This is a functional local proof, not a pure WMBridge solution or
evidence that every ATE-40 production acceptance gate passes. Newly added numbered
shortcuts still require a separate Dock registration that this refresh does not do.

## Gap 1: make Dock discover the created Desktop

`SLSDetectDisplays` and an unconfigured virtual display did not trigger the needed
reconciliation. Applying one 128×128 mode to a process-owned `CGVirtualDisplay`
did: Dock's count rose from three to four, and an explicit Mission Control
inspection showed the newly created Desktop 222. Original Jump Desktop mode 90,
physical mirror mode 55, current Desktop 3, and existing Space order stayed intact.

Keeping that virtual display alive for two seconds also displayed macOS's
new-display setup dialog. The full creation trial for Desktop 229 was functional
but failed that visual requirement. `setIsReference:` did not avoid the dialog.

The working variation releases the virtual display immediately after applying
its initial mode, then observes reconciliation for one second. A local
autorelease pool is essential: otherwise framework autoreleases can keep the
display alive until the helper exits. The final trials recorded approximately
38 ms from the first creation callback to the final removal callback. No owned
virtual display remained in the online list; both original modes, their bounds,
and mirror relationship were unchanged. These are actual display lifecycle
events, not synthetic notifications or unchanged-configuration requests.

Runtime Objective-C signature checks precede allocation. On this OS,
`CGVirtualDisplayMode` takes 32-bit width/height, unlike some external headers.
The first mismatched-signature trial refused before mutation. The code supports
only the inspected single-screen configuration, optionally a single mirror group.

## Gap 2: native entry and numbered registration are separate

A guarded native Mission Control control created Desktop 217, then removed that
exact ID and recorded UUID. After that cycle, the same numbered-3 shortcut that
had timed out now entered original test Desktop 168 in 299 ms; a saved typing
fixture passed. Returning to Desktop 3 also passed. This supports the earlier
Dock analysis: its native add/remove paths update numbered hotkey registrations;
its display-rebuild path updates its Space model without making that call.

The next fresh WMBridge Desktop, 222, became visible after a virtual display
refresh but numbered-4 entry still timed out. The control did not repair future
registrations. A read-only trace of a successful existing numbered shortcut also
showed a process-local system-event handle; it is not a stable action ID to replay.
No guessed event handles, Dock injection, Dock restart, privileged notification
delivery, preference edits, or Dock PPT service were used as repairs.

The CLI therefore places its new Desktop immediately after the starting current
Desktop and uses the actual enabled native next-Desktop binding (action 81).
Fresh native census checks verify entry and preservation of existing Space IDs
and their relative order. It requires the binding to be enabled when `--enter`
is requested. This completes creation and entry but does **not** claim repaired
numbered shortcuts beyond Dock's previously registered range.

## Final live trials

All paths below are relative to `.build/ate-40-manual/` in the ATE-40 workspace.
Both trials began with `[3,176,168]`, current 3, and Dock count 3.

| Trial | Created ID / native UUID | Ready / entered from start | Result |
| --- | --- | --- | --- |
| `e2e-pulse-1/creation` | 233 / `CEA1241A-EE56-4260-AF56-B29CEED94078` | 1,522 / 2,149 ms | Dock 4, native adjacent entry 593 ms, saved typing passed. |
| `trial-2mbtsS/creation` | 234 / `46F15223-94AE-479C-A1EA-EED3AD3F24D7` | 1,499 / 2,124 ms | Actual `mise run desktop:create -- --enter` exited successfully, Dock 4, native adjacent entry 590 ms. |

These timings begin inside `create-ready`; they exclude CLI preflight and the
XcodeBuildMCP build/launch overhead. The recorded trial's fixture was visible and
on active Space 233, saved `ATE40 verified typing`, and closed window 4103.
Input-to-save took 216 ms after entry. The second CLI run did not create a typing
fixture. Both recorded unchanged focus, pointer, and all existing layer-0 window
bounds through creation/refresh, before optional entry. Original window memberships
were not byte-identical: existing AccessibilityUIServer 16, Finder 20, and
Calculator 1116 gained the new Space while retaining their original memberships.
The reports retain that difference rather than labeling all memberships unchanged.

The full movie for 233 contains 47 decoded samples across two contact sheets;
every sample was reviewed. It shows the ordinary adjacent Desktop animation and
test fixture, with no Mission Control overview, display setup dialog, or original
resolution change observed. A preexisting SecurityAgent prompt was already
visible before the trial and remained visible; the trial did not interact with it.
The movie duration is 12.002 seconds, nominal rate 8.677 fps, maximum inter-sample
gap 0.617 seconds, last decoded sample at 5.267 seconds. Sparse/static capture
does not establish that no frame could flash between samples or after the last
sample. The CLI also checks for new visible Control Center helper windows during
its one-second post-release observation; both final reports saw none. This is a
bounded observation, not a guarantee across other machines or timing conditions.

Both final trials returned through the actual engine's existing numbered-1
route before removing only their own inactive, UUID-verified Desktop. Cleanup
refreshes Dock too. Temporary Desktops 217, 222, 227, 229, 233, and 234 were
reconciled and removed. Original Desktop 3, user-created 176, and original test
168 remain in order. The first combined trial 227 stopped after an immediate
placement read raced the void dispatch; the harness now polls that same attempt
for up to one second and never repeats the move.

## Implementation and use

From the ATE-40 workspace, with Atelier quit and the disposable session available:

```sh
mise run desktop:create -- --enter
```

Omit `--enter` to leave the starting Desktop active for a manual inspection.
The command prints the exact trial's status and cleanup commands. Return to an
original Desktop and close saved test windows before cleanup. `--raw` preserves
the original WMBridge-only experiment. No production application source changed.

`Ready.swift` composes the mechanisms under the existing mutation lock and durable
ownership journal. An uncertain create, placement, refresh, or entry is reported
without replay. `DisplayRefresh.swift` checks restoration and setup UI;
`NativeControl.swift` and `NativeInput.swift` contain the separate bounded
diagnostics. Read-only status remains distinct from functional entry proof.

## Local artifacts and external leads

Primary local reports are `creation/ready-result.json` in each final trial,
`return-output.jsonl`, and `creation/cleanup-ready-result.json`. Movies and raw
reports remain private and gitignored. SHA-256 anchors:

| Artifact | SHA-256 |
| --- | --- |
| `e2e-pulse-1/create.mov` | `09312355f768b856627509b29237b94fcaea4bff7dcf2a4b28194a1c4a8dc2d4` |
| `e2e-pulse-1/creation/ready-result.json` | `9c207749a70f2555dedec5ade54468c896e2648009f17990c5ed47722e7ccc1b` |
| `e2e-virtual-2/create.mov` (setup dialog) | `d06161caa27495ab1a1aaa75f3229b6fab2c221e65c7e9f914d993fdfe0d1509` |
| `e2e-virtual-2/pulse.mov` (standalone short refresh) | `62c3cc3a65f1847b37ae00854bf2802be20b87f497179da7fb35ca3062644ceb` |

The native registration control lives under `native-registration-control/`;
display detection trials remain under `trial-36rXDA/`, and fresh Desktop 222
under `trial-zn0F8O/`. Dock logs are in `.build/ate-40-diagnosis/dock-virtual-refresh.log`.

External sources supplied leads; the actual results above come from local trials:

- [Display detection research](https://github.com/hevengo/displayplacer-layout-manager/blob/main/display-port-recovery-research.md) suggested soft detection; local disassembly established its callable signature and the live trial was negative.
- [Chromium's virtual display test utility](https://chromium.googlesource.com/chromium/src/+/cca923fbde2d338f3730885e0dbe734eee8465a2/ui/display/mac/test/virtual_display_mac_util.mm) demonstrates the descriptor/settings/object lifecycle.
- [Private display headers](https://github.com/Fuzzy-Team/virtual-monitor-helper/blob/main/CGVirtualDisplayPrivate.h) supplied selector names; runtime signatures took precedence over header declarations.
- [HiDPIVirtualDisplay](https://github.com/knightynite/HiDPIVirtualDisplay) discusses object lifetime, relevant to the autorelease correction.
- [BetterDisplay setup-dialog discussion](https://github.com/waydabber/BetterDisplay/discussions/4283) and [ActiveSpace](https://github.com/PerpetualBeta/ActiveSpace) document related virtual-display behavior. Neither project was installed or adopted as the implementation.

`mise run wmbridge:test` passed all 5 Swift and 16 Node tests after the final
changes. Native build/run/test work used XcodeBuildMCP. Final cleanup reports
confirm Dock count 3, current 3, exact original IDs `[3,176,168]`, unchanged
display configuration, and no setup UI observed during either cleanup refresh.
