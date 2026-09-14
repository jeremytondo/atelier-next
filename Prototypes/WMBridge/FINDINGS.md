# ATE-40 verdict — updated September 14, 2026

**Proceed with a small production adapter, gated to macOS 27.** On macOS 27.0
(26A428), arm64, SIP fully enabled, one nonmirrored display, raw WMBridge
creation registers with Dock automatically: Mission Control shows the new
Desktop, the newly required highest numbered shortcut enters it through the
production engine's existing switch, native adjacent entry works, and saved
typing lands on the new Desktop. No Mission Control overview or display setup
UI appeared in the reviewed recordings. See
[the macOS 27 evidence](Evidence/2026-09-14-macos-27.md) and
[the prepared-entry measurements](Evidence/2026-09-14-prepared-entry.md).

The September 13 verdict below stands for macOS 26.5.2. On that build the
created Desktop needed a transient virtual display before Dock showed it, and
new numbered shortcuts were never registered. Two displays, fullscreen
neighbors, and the mirrored configuration on macOS 27 remain untested.

---

# ATE-40 local verdict — September 13, 2026

**Do not adopt this operation on the tested configuration.** Two calls produced
new managed type-0 IDs, but the existing native switching path could not enter
either one. Native Control–Right could not reach the first, and Mission Control
showed only the two original Desktops while the census contained three. This
fails the required native Desktop experience, despite fast census creation.

This is new behavioral evidence following
[the earlier research](../../docs/space-creation-research.md). It does not change
the historical findings or rule out the reported behavior on other OS builds.

## Environment and separation of evidence

- Local macOS **26.5.2 (25F84), arm64, SIP enabled**. HS2 pin **0.0.12**, revision
  `7a218ddfc3c6c49246bff3e538c9c46e29a59caf`; no pin or production-default changes.
- The user explicitly identified the current session as disposable. Initial
  configuration: one Jump Desktop virtual display, logical 1470 × 922 at 2×,
  separate Spaces enabled. Native display identifier
  `BF1BDA7D-2A5B-41FB-933D-405802D73ED3`; original Space IDs `[3, 14]`.
- A different display identifier, `20B77EC1-97B7-45BD-8A54-C91C9A356516`, appeared
  during follow-up checks. We did not reconfigure displays. This bounds the
  result to the recorded configuration and prevents a full GUI-state-restoration
  claim. Cause and timing relative to all observations were not established.
  A final probe identified that display as GLKVM (2560 × 1440, 1×). An attempted
  physical-display comparison then refused **before dispatch** because the
  identifier had changed back to the Jump Desktop display. It created nothing;
  stable physical-display creation remains untested.
- The installed Atelier instance was quit for mutation trials. The actual HS2
  host trial used a private copy's headless self-test entry point and an isolated
  shortcut journal. The copy lacked Accessibility trust; the command-line
  engine reported trust and could switch the original Desktops.
- [KiwiDesk PR 990](https://github.com/KiwiCanopy/KiwiDesk/pull/990) and
  [Native Space Kit's pinned findings](https://github.com/Fjx-dylanZ/native-space-kit/blob/01b7e49718d500ed08add3e95533e2b9b41b2561/docs/findings.md)
  are external reports on different builds. Their successes were not imported
  as local results. No prototype/reference implementation is a dependency.

## What was observed

| Trial | Native result | Dispatch start to census confirmation | Entry |
| --- | --- | ---: | --- |
| Standalone AppKit event loop | New ID `126`, raw type `0`, exactly one addition | 4.653 ms | Numbered native shortcut timed out; current remained `3` |
| HS2 → actual Atelier engine, explicit `NSApplicationLoad` | New ID `132`, raw type `0`, exactly one addition | 2.017 ms | HS2 copy refused for missing AX trust; trusted engine also timed out, current remained `14` |

There were **two dispatched create operations**, each using options `0`, an empty
dictionary, the synchronous object-returning `performWithWMBridgeDelegate`, and
an ABI-checked unsigned 64-bit `spaceID`. Three earlier harness/preflight attempts
dispatched nothing: a conflicting test-lock implementation caused two refusals;
the third observed a non-console/unavailable session precondition. Fresh census
reads confirmed no additions before the first dispatched trial. Those failures
remain in the local logs and were not counted as API failures.

The figures above measure from immediately before the private dispatch to a
fresh census, **not keyboard-to-ready latency**. They exclude preflight,
journaling, process launch, and compilation. Early raw reports used the name
`inputToNewIDMilliseconds`; the final code calls it
`dispatchToNewIDMilliseconds`. The real HS2 create-and-enter attempt returned its
creation evidence and activation refusal in 108.683 ms, measured in JS after the
host's initial snapshot. No successful input-to-active-ID or typing-readiness
measurement exists: both saved typing checks refused to send input because the
expected Desktop was not active.

Creation `126` preserved the active ID, exact focused Ghostty window, and pointer.
Creation `132` preserved active ID and pointer; focus could not be verified from
the untrusted host. The existing AccessibilityUIServer and Calculator windows,
and a Finder desktop surface, gained membership on the new ID without losing
their original memberships. Thus a claim that **all memberships were unchanged**
would be false. They retained their original memberships after cleanup. Other
recorded changes during follow-up involved Control Center/menu/background
surfaces and the display reconfiguration; the summary preserves their IDs.

The native-control comparison discriminates the failure from a completely broken
input transport: the same trusted engine switched `[3 → 14 → 3]` successfully
(approximately 413 and 314 ms including snapshot/verification). For `126`, native
Control–Right switched `3 → 14` and then remained on `14`. A deliberate native
Mission Control invocation showed only **Desktop 1** and **Desktop 2**, although
the census still included `126`. Mission Control was used for this coexistence
observation, never as a creation fallback. `132` also failed numbered entry after
explicit AppKit initialization. Trackpad gestures were not tested.

Read-only signatures matched the proposed ABI. An additional process-local,
forwarding trace observed
`NSWMWindowCoordinator.performSynchronousBridgedWindowManagementOperation:`
answering `SLSBridgedCopyManagedDisplaySpacesOperation` with the expected result.
The fallback delegate was instrumentable but was not called for this read. The
trace restores the original methods. This establishes an answering AppKit
delegate for the read; it does not establish that a create operation receives all
the OS-side coordination needed for Dock/native navigation. We did not trace or
modify creation's implementation to manufacture a pass.

## Recordings and cleanup

Both creation recordings were decoded and all frames in their contact sheets
were inspected. Neither contained a Mission Control or concealment frame.

| Capture | Duration | Decoded frames | Reported nominal rate | Largest presentation gap |
| --- | ---: | ---: | ---: | ---: |
| `trial-04.mov` | 12.002 s | 24 | 1.983 fps | 0.600 s |
| `trial-05-host.mov` | 12.007 s | 9 | 0.500 fps | 2.917 s |

These are sparse, variable captures from `screencapture`, not a fixed 60-fps
zero-flash proof. The videos support only the absence of flash in their captured
frames. Their paths, SHA-256 hashes, contact sheets, and frame data are recorded
in [the evidence summary](Evidence/local-2026-09-13.json). Raw journals, videos,
and the Mission Control screenshot remain in `.build/ate-40-evidence/`.

**Both owned IDs, `126` and `132`, were removed. No unresolved creation remains.**
Cleanup first refused unidentified occupancy. Read-only process-path inspection
identified WindowServer's per-Space menu/background surfaces; the narrowly scoped
classifier now recognizes those exact path/layer combinations. Calculator and
AccessibilityUIServer were accepted only while their recorded original Space
memberships remained intact, not because of their application names. No user
window was closed or moved by the experiment's cleanup code.

The second cleanup initially refused the changed display identifier. A fresh
reconciliation confirmed the same owned ID and native UUID survived; explicit
cleanup against the observed display then removed it with fresh occupancy and
inactivity checks. No dispatched cleanup was replayed. After that cleanup, Space
IDs/order were `[3, 14]`, current `14`, on display
`20B77EC1-97B7-45BD-8A54-C91C9A356516`. The final read-only probe retained those
IDs/order on the returning Jump Desktop display
`BF1BDA7D-2A5B-41FB-933D-405802D73ED3` (1470 × 924, 2×).
The raw `originalTopologyRestored: false` results remain intact: the first trial
ended on a different original Desktop, and the second saw a different display.
Both restored the original Space ID order. Private shortcut journals were empty
after engine shutdown. No user configuration was loaded by the copied host.
The saved TextEdit fixture was closed through its exact Accessibility window
after TextEdit's document AppleEvent timed out; its absence was verified. The
original `/Applications/Atelier.app` was relaunched and its helper was running
again. A final read-only probe confirmed that neither owned ID remained.

## Coverage matrix

| Required scenario | Result and boundary |
| --- | --- |
| Local 26.5.2 / 25F84 | **Blocked:** type-0 census creation works; usable native Desktop creation not demonstrated |
| Newer macOS 26 and macOS 27 | **Untested:** no other OS environment exercised; external reports remain separate |
| One display | **Partial:** two exact additions, inactive creation, original ID order preserved; native navigation failed |
| Two displays, separate Spaces on/off | **Untested:** creation refuses multiple screens before dispatch; placement not established |
| Fullscreen/tiled neighbors | **Untested live:** synthetic topology tests reject wrong raw types and preserve neighbor order |
| Native controls / external user changes | **Blocked/partial:** existing indexed switching works; created-ID switching and Control–Right failed; Mission Control omitted `126`; gestures untested |
| Rapid input, timeout, cancellation, restart | **Partial:** Node tests exercise busy refusal, helper timeout/restart without replay, and preserved created ID on activation failure; Swift journal tests cover restart; no live interrupted create dispatched |
| Display disconnect / external topology change | **Partial:** display identity changed; cleanup refused, reconciliation retained ownership evidence, explicit scoped cleanup succeeded; no change during a dispatched create was established |
| Unsupported bridge / capacity | **Partial:** missing capability is refused in fake-backed tests; capacity and changed native ABI not tested live |
| Cleanup | **Partial:** both owned IDs removed, original ID order/current initial ID retained; full display/focus restoration not claimed |

Automated checks passed: `mise run wmbridge:test` (5 Swift tests with case matrices
and 5 Node tests) and `mise run test` (22 Swift tests and 15 Node tests). Tests cover
exact additions, ambiguous/wrong IDs, wrong raw types/display, active-ID changes,
native reorder/deletion, delayed census, journal replay prevention, exclusive or
minimized occupants, missing capability, busy input, and activation failure.
Unit tests are not evidence of actual macOS navigation, focus, or visual silence.

## Recommendation

Stop production adoption for this tested configuration. The prototype preserves
the existing creation defaults and provides a reproducible negative result.
Repeat on a named newer OS build and a stable physical display before pursuing a
production adapter. A successful repeat must pass native Mission Control
inventory, indexed/adjacent navigation, focus/typing, placement, and a capture
with sufficient temporal coverage; type `0` plus a matching census is necessary
but demonstrably insufficient here. Treat the OS-side reason for the missing
native-navigation registration as unresolved, not as proof that WMBridge can
never work with SIP enabled.
