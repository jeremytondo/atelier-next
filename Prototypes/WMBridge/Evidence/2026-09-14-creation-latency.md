# ATE-40: reduce the manual command's creation latency

This supplements [the first working flow](2026-09-14-ready-flow.md). It changes
the experiment's scheduling and invocation overhead, not the creation mechanism
or native switching animation. Alternative creation methods were not investigated
in this follow-up.

## Changes

The CLI previously launched XcodeBuildMCP twice: once for a read-only probe and
once for creation. Native creation already performs capability, SIP, session,
and topology checks. It now also resolves the sole display when passed `auto`,
so the manual CLI needs only one build/run invocation. The preflight probe is
retained in the creation intent. Explicit display guards remain available, and
`desktop:create -- --check` remains read-only. No resident service was added.

Previously the refresh waited a fixed second before starting native entry. It
can now proceed once a display callback batch has completed, no new callback has
arrived for 50 ms, and fresh reads confirm all of the following:

- Dock's Desktop count agrees with the expected native topology.
- Exact Space IDs, types, relative order, display, and current Desktop match the
  state after placement.
- Original online display IDs, modes, bounds, and mirror relationship match.
- The setup UI query succeeded and no new setup window has appeared.

The existing one-second post-release setup UI observation continues during native
entry and any typing fixture. The command waits out any remaining observation
time before returning. A late setup window or unavailable query produces an error
even if entry succeeded, retaining the created ID for inspection. No mutation is
replayed. If callback readiness is not confirmed early, the existing bounded wait
and final state checks remain; the deadline itself is not proof of readiness.

## Measurements

Local macOS 26.5.2 (25F84), arm64, SIP enabled, Jump Desktop display 27 as mirror
source with physical display 3. Original modes are 90 and 55, with one AppKit
screen at logical 1600×1000. The fresh starting topology for this follow-up was
`[3,256,244]`, current 3. These differ from the earlier session's Desktops and
are the resources preserved by this follow-up.

The private evidence parent is `.build/ate-40-manual/speed-6Dlqqk/`. Both timed
trials used the actual `mise run desktop:create -- TRIAL --enter` command with
the build already up to date. A parent Node process measured elapsed time around
the entire mise invocation using a monotonic clock and retained stdout/stderr.

| Measurement | Before (`before/`, ID 260) | After (`after-1/`, ID 263) |
| --- | ---: | ---: |
| Whole mise command, including startup and final observation | 4,711 ms | 2,655 ms |
| Native create-ready start to verified entry | 2,106 ms | 1,168 ms |
| Native start to Dock readiness | 1,494 ms | 561 ms |
| Refresh work before proceeding | 1,354 ms | 425 ms |
| Post-release UI observation | 1 second before entry | 1,006 ms, overlapped with entry |

This first pair reduced whole-command elapsed time by 44% and the native interval
to entry by 45%. One timing pair is evidence of the removed overhead, not a latency
distribution. Whole-command measurements include tool startup; native timings do
not. The CLI's printed `Command time` begins inside the Node wrapper, so it excludes
mise/Node startup and is slightly shorter than the parent measurement.

Both creations produced exactly one new type-0 ID and Dock count 4. The faster
trial reported completed callback readiness, unchanged focus/pointer and existing
layer-0 window bounds through refresh, restored display configuration, and no new
display setup UI throughout the full observation window.
The old baseline's foreground app remained Finder but neither snapshot exposed
a focused window; its `focusUnchangedThroughRefresh=false` reflects missing focus
evidence. It is a timing baseline, not a successful focus-preservation test.

## Checks and ownership

Automated coverage checks automatic display selection against empty, multiple,
and mismatched display inputs; pending/incomplete/restarted display callback
batches; and the requirement for fresh state agreement. CLI tests cover one
invocation, preflight refusal, uncertain ownership, entry failure, and late
observation failure without success reporting, replay, or automatic cleanup.

The baseline trial returned to Desktop 3 and removed only its owned Desktop 260.
After the faster trial returned to 3, cleanup initially refused before dispatch:
an unrelated Atelier instance from the `atelier-ate-36` workspace had introduced
a new all-Spaces window (4595, PID 72542) absent from the trial baseline. The
occupancy guard remained intact; live testing paused for session isolation.
The process exited without agent termination, its window disappeared, and a
fresh occupancy check allowed cleanup of only Desktop 263. The user subsequently
confirmed that the other Atelier instance was no longer running.

## Recorded validation

After session isolation, `recorded/` ran `create-ready ... auto --enter
--test-typing` through the existing recording task. It created Desktop 265,
UUID `2FC78D53-BB50-475D-AA64-1AA01DC6DB99`. Dock was ready after 617 ms;
native entry was verified after 1,224 ms. The full setup UI observation lasted
1,012 ms, with complete queries and no new setup windows. The saved fixture
was visible on active Space 265 and typed successfully in 184 ms from fixture
start; its window 4615 closed on return. Focus, pointer, and existing layer-0
window bounds matched through refresh. Original modes/mirroring were unchanged.

Every one of the movie's 58 samples was reviewed across two contact sheets.
The capture showed the ordinary native slide and the typing fixture, with no
Mission Control overview or display setup dialog observed. The movie is 11.985
seconds long, nominal 13.488 fps, maximum inter-sample gap 0.600 seconds, last
sample at 4.267 seconds. Static/sparse capture does not prove an absence of
unrecorded flashes. Raw timing and frame metadata stay beside the movie.

SHA-256 anchors:

- `recorded/create.mov`: `e9ddb87abc6fa8f454bc31d9e438d731090cc3ee2b4010aba858965b6e296411`
- `recorded/creation/ready-result.json`: `5dd53b408e1594e8215708e8fec2d5e808e0a5192c364991b7e525aace6a8391`

`mise run wmbridge:test` passed 7 Swift and 16 Node tests. Native builds, tests,
and runs used XcodeBuildMCP; production code and settings remain unchanged.

Final cleanup removed all three owned trial Desktops (260, 263, 265) after
verified native return to 3. Each cleanup report confirms Dock count 3, exact
original order `[3,256,244]`, current 3, and restored display configuration.
