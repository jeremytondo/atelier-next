# Native menu validation

Native cross-process tiling is confirmed for four TextEdit placements on macOS
26.5.2 (25F84), Apple silicon. Each placement ran once against a freshly launched
temporary document, using `AXIdentifier` lookup and `AXPress`. No keyboard or
mouse events or frame assignments were used. These are capability checks, not
a reliability benchmark.

Runs occurred September 10, 2026, 19:28–19:29 America/Chicago (September 11,
00:28–00:29 UTC). Accessibility became available after enabling the `node`
entry. The preceding TCC attribution diagnostics identified the responsible
runtime as `/Users/jeremytondo/.local/share/mise/installs/node/26.4.0/bin/node`.

Every document began at `(146,66,673,439)`. Coordinates below are WindowServer
bounds in points, expressed as `(x,y,width,height)`.

| Placement / transcript | PID / window ID | Resulting bounds | Native WindowManager state | Restore delta `(x,y,width,height)` |
| --- | --- | --- | --- | --- |
| [Left](left-exact-restore.txt) | 10648 / 175913 | `(0,30,735,894)` | `leftHalf` | `(-1,0,+1,+1)` |
| [Right](right.txt) | 10899 / 175921 | `(734,30,735,894)` | `rightHalf` | `(0,0,+1,+1)` |
| [Top left](top-left.txt) | 10971 / 175929 | `(0,31,735,447)` | `topLeftCorner` | `(-1,-1,+1,+1)` |
| [Fill](fill.txt) | 11094 / 175937 | `(0,30,1470,894)` | `fill` | `(-1,0,+1,+1)` |

All eight AXPress calls (four placements and four untile actions) returned
success. Pointer coordinates before and after each pair were identical. The
[system log](windowmanager.txt) records the requested native placement for each
specific window, including its untiled frame, followed by an `untile request`.
The removal lines redact window identity, so their association relies on the
isolated sequential runs and timing; the addition lines identify each window.

Exact restoration failed in all four trials: each frame component returned
within one point of its original value. The first trial deliberately retains
the original failing exact-equality assertion and its raw output. After that
observation, the probe was changed to report both exact equality and a one-point
geometric tolerance, together with the full delta. The three subsequent trials
passed that tolerance; none passed exact equality. The cause of the discrepancy
has not been isolated, and it should not be described as proven rounding.

Native-state confirmation comes from the targeted native command plus correlated
WindowManager transitions, independently of the relaxed geometry criterion.
The wrapper labeled the first run “Build failed” because the probe exited with
a failed restoration assertion; the transcript shows compilation succeeded.

The probe never requests menu expansion and does not move the cursor. Visual
menu exposure, focus flashes, and animation quality were not recorded, so this
result does not certify a seamless user experience. These recorded fixture
tests do not cover other applications, multiple windows, desktop-wide
arrangements, multiple displays, non-English menus, or repeated-cycle drift.

The successful fixture sequence includes launching TextEdit, waiting for a
window, activating it, and invoking native tiling. This establishes that simple
sequence for this fixture, not general window selection for arbitrary apps.

Reproduce from the repository root, with TextEdit closed:

```sh
swift run --package-path Prototypes/NativeWindowTilingPOC native-window-tiling-poc right --standard-app-menu-smoke-test
```

Replace `right` with another placement. Inspect the deltas and corroborate with
WindowManager logs; an exit code alone does not certify native state.

## Hands-on follow-up

On September 10, 2026, after trying the focused-window tester, the user reported:
“Ok, that actually works pretty well.” The tester invokes the same native menu
dispatcher as the fixture, following a five-second countdown, and leaves the
placement visible for inspection. See the
[manual workflow](../../README.md#try-it-on-your-own-windows).

This is qualitative evidence that the interaction is usable in the user's
trial. The apps, windows, placements, and number of trials were not specified;
no screen recording or end-to-end latency measurement accompanied the feedback.
Keep this observation separate from the four instrumented TextEdit trials above.
