# Prepared entry with the native slide retained

The user's target is the pause before the slide starts. The normal native slide
is explicitly preferred. This follow-up moves native helper startup ahead of the
create request; it does not change the animation or pre-create a Desktop.

## Environment and scope

macOS 27.0 (26A428), SIP fully enabled, trusted Accessibility, unlocked console,
one Jump Desktop Display 1 (CG ID 5, 1470 × 922 points, scale 2), display UUID
`BF1BDA7D-2A5B-41FB-933D-405802D73ED3`. The user authorized this disposable session.
Fresh baseline order was `[3, 37, 36]`, current `37`. Those IDs belong to the
baseline and were preserved. No Atelier application instance was running.

This remains an ATE-40 prototype. Production Atelier source was not changed.
Read [the macOS 27 registration evidence](2026-09-14-macos-27.md) for the earlier
finding that this build can register a raw WMBridge Desktop without a display
refresh.

## What preparation does

`mise run desktop:prepare` builds/launches `wmbridge-experiment serve-ready`
through XcodeBuildMCP, initializes AppKit and the WMBridge preflight, then keeps
that windowless process waiting on a private local Unix socket. The manual CLI
sends creation directly to that process, avoiding another Node wrapper,
XcodeBuildMCP invocation, build check, and native process launch.

Every create request still performs fresh session/topology checks, creates an
exclusive journal, acquires the existing mutation lock, creates once, confirms
adjacent placement and Dock registration, and posts the user's enabled native
next-Desktop shortcut (action 81). Preparation creates no Desktop. It holds no
mutation lock while idle. Cleanup uses the same existing exact-ID/UUID and
occupancy guards.

The helper uses owner-only state and socket permissions, checks the connecting
UID, serializes requests, refuses a running Atelier instance, and bounds startup
and native operations with ten-second watchdogs. Native source changes invalidate
the prepared session. The transport never retries or sends a cold fallback after
a submitted request fails. An expired helper can use the cold path only before
any request is sent. `desktop:stop` stops the helper without removing Desktops;
the helper also has a ten-minute idle timeout.

## Measurements

Local evidence root:
`.build/ate-40-manual/faster-27-DUFlba/` in the ATE-40 workspace.

| Trial | Returned ID | CLI to slide request | CLI result | Native shortcut to confirmed entry |
| --- | --- | --- | --- | --- |
| `animated-before` (cold CLI) | 38 | Not instrumented | 2058.7 ms | 573.8 ms |
| `warm-second` (prepared, with extra Node wrapper) | 39 | 241.9 ms | 818.7 ms | 560.2 ms |
| `warm-direct` (prepared, direct CLI socket) | 40 | 192.4 ms | 767.7 ms | 573.3 ms |

These are individual live trials, not statistical bounds. CLI timing starts in
`manual.main`, so it excludes mise/shell and initial Node startup. The slide
request timestamp is recorded immediately before posting the native key events;
it is not a measurement of the first animated pixel. Cross-process dispatch
latency uses the wall clock; native duration and CLI completion use monotonic
clocks. The unchanged roughly 0.57-second native entry interval is consistent
with retaining the ordinary animation. The total measured CLI reduction is
about 63% compared with the cold baseline.

The recorded `warm-typing-final` trial created ID 43, dispatched entry 206.0 ms
after entering the native creation stage, confirmed native entry at 794.9 ms,
and finished the saved typing fixture at 954.0 ms. The fixture reported
`typed`, `visible`, `onActiveSpace`, and `windowClosedOnReturn` all true.
Dock registered the new Desktop automatically; no virtual display was allocated.
Pointer position and existing application window bounds were unchanged through
creation. Finder had no known focused AX window, so the report does not establish
focus preservation.

The movie decodes to 65 samples in two contact sheets. Every sample was reviewed:
the Desktop slides normally and the saved typing fixture appears on the
destination. No Mission Control overview or display setup UI appears in those
samples. Sparse capture does not prove the absence of an uncaptured flash and
the recording clock is not synchronized precisely enough to claim first-pixel
latency from its timestamps.

Movie: `warm-typing-final.mov`.
SHA-256: `07e3ab0c1c2acbb74c42914935ba07d75a3ab180a1b39e9fdd89dcafafb57cab`.
Decoded index: `warm-typing-frames/frames.json`.
SHA-256: `bd178610ba9728391d9e9956fdf08675487a74a1424f2aae0381e3e297e8331d`.

## Failures, checks, and restoration

The first socket trial (`warm-first`) encountered an EPIPE before dispatch.
Darwin's accepted socket inherited the listener's nonblocking flag, causing a
reader race with the client's first write. The server now explicitly clears
that flag. Fresh census evidence confirmed the unchanged baseline after the
failure. The corrected server accepted clients delaying their first write by
20, 100, and 300 ms (`session-handshake.json`); unsupported requests were refused.

The first recording invocation (`warm-typing.mov`) supplied a missing parent
directory. The exclusive journal guard refused it before mutation. A fresh probe
confirmed the baseline; the successful recording used a separate, explicitly
created private parent and new journal. Both failed attempts remain recorded.

`mise run wmbridge:test` passed 9 Swift and 23 Node tests. The added transport
tests exercise fragmented replies and verify exactly one request after timeout,
disconnect, malformed output, or oversized output. Existing manual tests now
also await asynchronous success/failure and preserve no-replay behavior.
Two isolated CLI launch fakes verify that build failure and process exit before
readiness preserve launch evidence and clear the unusable session pointer. A
final native prepare/reuse/stop check retained the same PID 22778 on reuse and
confirmed its exit (`final-session-lifecycle.json`); it created no Desktop.

Every successful trial returned to baseline ID 37 using the actual engine's
native numbered switch before exact-journal cleanup. IDs 38, 39, 40, and 43 were
removed; no baseline ID was removed. `final-probe.json`, `final-dock.json`,
`final-diagnose.json`, and `final-audit.json` record restored IDs/UUIDs/order/current
and screen description, Dock count 3, and a closed overview. Captured helper PIDs
18109 and 20177 exited after explicit stops, and the active helper pointer was
removed. No Atelier application instance remained running. Idle expiry is
implemented but was not exercised by waiting ten minutes in this run.
