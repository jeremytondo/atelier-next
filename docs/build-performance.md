# ATE-37 build workflow measurements

These are individual observations from September 13, 2026 (America/Chicago),
not median or p95 claims. The issue's hosted baseline and this developer Mac
have different CPU capacity and cache state; their durations are not directly
comparable. The implementation is in the mise tasks, workflows, and scripts;
[release documentation](releases.md) describes operation and state locations.

## Completed follow-up validation

The missing hosted scenarios and cold-build investigation are complete.
[Machine-readable measurements](build-benchmarks.json) retain 25 successful
run/attempt records, including source revisions, input keys, phase times,
feedback timing, and cache transfer bytes/steps. Historical measurements below
precede the final architecture correction unless explicitly identified.

### Final implementation, c2775ef0

| Scenario | Elapsed | Total job execution | First JS result | Evidence |
| --- | ---: | ---: | ---: | --- |
| Cold check, both native caches absent | 248 s | 257 s | 15.25 s | [Attempt 1](https://github.com/jeremytondo/atelier-next/actions/runs/34802488296/attempts/1) |
| Same-source warm full check | 93 s | 103 s | 21.47 s | [Attempt 2](https://github.com/jeremytondo/atelier-next/actions/runs/34802488296/attempts/2) |
| Signed, notarized branch dev release | 287 s | 275 s | 27.06 s | [Release](https://github.com/jeremytondo/atelier-next/actions/runs/34802498406) |

The final release took 4m47s versus the audited 8m40s, an observed 233-second
reduction (45%). It compiled the host once in 192.2 seconds; packaging took
32.9 seconds, including 23.4 seconds waiting for notarization. Signing, full
runtime/XPC and configuration probes, notarization, stapling, and Gatekeeper
passed. Downloaded ZIP/manifest checksums passed, and the host, CLI, and XPC
service each contained only arm64. No merge into `main` was needed.

The warm check ran Debug tests for 37.85 seconds and the bundle check for
7.72 seconds, with no host or Release-helper compilation. Compressed host and
helper outputs were 4,968,315 and 714,958 bytes. Actions transferred 4,958,718
and 716,738 bytes; restore steps rounded to zero and one seconds in GitHub's
records. Extraction plus receipt validation took 1.61 and 1.45 seconds. On
the cold run, packing took 1.85 and 1.24 seconds, and each save took one
second. Warm hits did not repack or save. These costs support the compact caches.

### Repeated scenario measurements

These repetitions preceded the final `ARCHS=arm64` correction. The JS/docs
classifier, tests, cache validation, and bundle-probe behavior were unchanged
by that correction. Final-revision observations are reported separately above.

| Scenario | Elapsed samples, seconds | Job seconds | First JS result, seconds | Evidence |
| --- | --- | --- | --- | --- |
| Original `main` control | 184, 213, 221 | 176, 206, 209 | 67.07, 65.68, 98.18 | [3 attempts](https://github.com/jeremytondo/atelier-next/actions/runs/34801101500) |
| Docs-only PR | 38, 34, 32 | 32, 25, 25 | 21.98, 17.92, 17.04 | [3 attempts](https://github.com/jeremytondo/atelier-next/actions/runs/34800655770) |
| JS-only PR, cache miss | 315 | 327 | 24.25 | [Attempt 1](https://github.com/jeremytondo/atelier-next/actions/runs/34800655127/attempts/1) |
| JS-only PR, warm caches | 68, 69, 71 | 76, 74, 75 | 17.98, 18.72, 25.57 | [Attempts 2–4](https://github.com/jeremytondo/atelier-next/actions/runs/34800655127) |
| Native change, cold caches | 352, 427, 249 | 360, 428, 251 | 19.20, 18.42, 17.38 | [Attempts 1, 3, 5](https://github.com/jeremytondo/atelier-next/actions/runs/34800706079) |
| Same native change, warm repeat | 83, 118, 112 | 91, 122, 113 | 20.59, 17.02, 16.90 | [Attempts 2, 4, 6](https://github.com/jeremytondo/atelier-next/actions/runs/34800706079) |
| Branch dev release | 326, 337, 409 | 314, 323, 394 | 51.21, 25.80, 36.42 | [1](https://github.com/jeremytondo/atelier-next/actions/runs/34799685091), [2](https://github.com/jeremytondo/atelier-next/actions/runs/34801103108), [3](https://github.com/jeremytondo/atelier-next/actions/runs/34801469732) |

Docs samples skipped the native job and passed the final check. Warm JS samples
compiled neither host nor helpers and did not run native tests; each assembled
and probed current resources. The cold JS sample built verified dependencies
before probing. Original Check had no change selection, so its unchanged-source
control represents the old full-gate path for documentation edits; it is not
a separately measured old docs PR. The audited JS-only PR baseline is 244 seconds.

Temporary PRs [#3](https://github.com/jeremytondo/atelier-next/pull/3),
[#4](https://github.com/jeremytondo/atelier-next/pull/4), and
[#5](https://github.com/jeremytondo/atelier-next/pull/5) targeted `42650454` with
only a JS comment, documentation, or a Swift comment. They are closed without
merging. Cold repetitions removed only benchmark-owned host/helper cache IDs;
source, input keys, tool caches, flags, and tests stayed constant. GitHub's PR
cache isolation prevented them from reusing PR #2's native outputs.

Initial elapsed times start at creation; reruns start at attempt start and
exclude the rerun queue. First-JS-result times use timestamped passing-result
lines. Native-result times in the JSON are completed invocations, including
compilation, not test-body durations. After-change native runs report the same
macOS image, Apple M1 virtual CPU, three logical CPUs, and selected Xcode 26.6.
The original-main controls retain unpinned mise (observed 2026.9.7 versus the
implementation's 2026.6.14). These are observed ranges, not randomized,
equal-coverage comparisons or median/p95 estimates.

### Cold-build investigation

Identical native inputs produced host times of 188.3–342.6 seconds. Debug
compilation also varied from 52.7–114.4 seconds before Release helpers started,
so the slowest result cannot all be assigned to helper overlap. Delaying
Release helpers until the host finished in temporary
[PR #6](https://github.com/jeremytondo/atelier-next/pull/6) produced 260- and
346-second checks. Those ranges overlapped the existing graph and added a
31–38-second helper stage after the host. The experiment is closed without
merging; the existing overlap is retained.

Raw logs exposed a concrete waste: `--arch arm64` selected the destination,
but Release compiled arm64 and x86_64. Earlier claims that builds were already
arm64-only were incorrect. The final command also sets `ARCHS=arm64`, and
architecture rejection has an explicit failure exit plus Intel/universal-output
fixtures. The script's input digest invalidates prior receipts and caches.
Fresh Check and release logs show eight Swift compilation tasks, all arm64,
versus sixteen with both architectures previously. Binary inspection confirmed it.

The final cold check's 248 seconds still exceeds the contemporary original
controls' 184–221 seconds. It also adds Release-helper compilation and a real
bundle probe, plus cache validation and transfer. No blanket cold-build
speedup is claimed. The demonstrated improvements are removal of duplicate
release builds and unsupported architecture work, faster repeated/narrow
feedback, and preservation of the stronger gate.

### Acceptance evidence

| ATE-37 criterion | Result |
| --- | --- |
| Cold, warm, JS, docs, and manual-release measurements | Complete; elapsed/job time, feedback, phases, transfer bytes/steps, source and keys retained in JSON |
| One host compilation per release; unchanged preparation retained | Passed in four new releases and preparation/reuse fixtures |
| Independent JS tests and early results | Passed locally and in hosted narrow/full runs |
| Invalid or stale build state cannot count as verified | Build/release fixtures pass for failed/interrupted preparation, changed inputs, corrupt archives, missing resources/licenses/XPC, and wrong architecture |
| Conservative selection and final failure propagation | Real JS/docs/native paths passed; other path classes, unavailable diffs, failures/cancellations and unexpected skips covered by fixtures |
| Distribution/configuration protections | Full signed publication passed; manual branch releases intentionally replace the ticket's original main-only policy at the user's direction |
| Relevant checks and full gate before PR publication | Passed; final code also passed hosted cold/warm checks and publication |

## Before

ATE-37 records a 272-second main Check, 244-second JS-only PR Check, and a
520-second release. The release spent 233 seconds in its gate and 216 seconds
packaging, including a second 155.1-second host build. Reading the completed
[release run](https://github.com/jeremytondo/atelier-next/actions/runs/34791454373)
with `mise run ci:report` confirms 520 seconds of workflow elapsed and 503
seconds of total job execution (481 package, 22 publish).

The original scripts in the new jj workspace built the host in 51.8 seconds
and ran the native build/test invocation in 15.4 seconds. Node's 12 tests took
0.049 seconds but waited for that native invocation. The original aggregate
gate also revealed that actionlint's implicit Git discovery fails in a
non-colocated jj workspace; workflow paths are now passed explicitly.

## Local observations after the changes

Machine: Apple M4, macOS 26.5.2, Xcode 26.6 (17F113), macOS SDK 26.5, XcodeBuildMCP
2.6.2, Node 26.4.0, mise 2026.6.14. Exact compiler/OS identities are retained
in the generated metrics. Test processes use private configuration directories.

| Scenario | Observed wall time | What ran |
| --- | ---: | --- |
| Full check with empty repository native build directories | 59.3 s | Host, Debug tests, Release helpers, portable checks, ad-hoc assembly/probe |
| Repeated full check with final task graph | 6.7 s | Tests and bundle probe rerun; native outputs verified/reused |
| Repeated host task | 0.60 s | Complete native input/output verification; no compiler invocation |
| Repeated preparation | 0.17 s | Source content verified; files/timestamps unchanged |
| Host cache verification and gzip creation | 1.17 s | 7,342,348-byte archive including resources/XPC/licenses/receipt |
| Helper cache verification and gzip creation | 0.56 s | 715,294-byte archive including three Release helpers/receipt |
| Host/helper archive extraction and verification | 0.76 / 0.53 s | Real compressed outputs restored under their producer locks |
| Bundle assembled from restored caches | 3.42 s | Ad-hoc signing and real runtime/configuration probes |
| JS-only edit and bundle check | 3.48 s | Host/helper compilation reused; current JS assembled/probed |
| Documentation-only portable profile | 8.84 s | JS, lint, release/build fixtures; no real native compilation |

An earlier warm task graph took 10.0 seconds; allowing the bundle probe to
overlap portable fixtures reduced the final observed gate to 6.7 seconds.
The JS-only observation used a temporary comment in `overlay.js`, restored
after the probe; neither native input key changed. The full gate was rerun
after rebasing onto `main` with its overlay fix and 15 JavaScript tests.

The native-directory-cold run retained the verified source download and the
machine's system caches; it is not a clean hosted-runner measurement. It
finished the helper Release build in 13.2 seconds after Debug tests while the
host compiled independently. The native XCTest and Swift Testing bodies take
milliseconds; the much longer invocation includes compilation and startup.

The unsigned host occupies about 28 MB and the helpers 2.4 MB before compression.
Xcode package sources alone occupy about 100 MB; SwiftPM's local build tree
occupies hundreds of MB. Only compact native outputs are enabled as Actions
caches. Their hosted transfer economics are recorded above;
there is no evidence here to justify caching all DerivedData or package trees.

A separate local retrieval of the 3,647,047-byte source archive took 0.52
seconds and matched the pinned SHA-256. Compressing Xcode's SourcePackages
tree took 1.45 seconds and produced 78,673,006 bytes, over ten times the host
payload. These observations support retaining verified local downloads while
deferring an Actions download/package-source cache pending a net-time win.

## Additional evidence and preserved checks

- Xcode creates an empty `xcshareddata/swiftpm/configuration` directory. It is
  now created during preparation, preventing this normal build write from
  invalidating the source receipt. A repeated preparation verifies the tree
  without rewriting files.
- Ad-hoc Release signatures cannot satisfy HS2's `.isFromSameTeam()` XPC
  requirements. The ad-hoc gate explicitly omits only that call. An Apple-signed
  local app passed the complete AppleScript/XPC, engine, runtime, helper-task,
  and configuration-preservation probes. Distribution retains the full probe.
- Shell fixtures cover unchanged/missing/corrupted output, executable bits,
  resources, XPC and license loss, changed pin/patch/lockfile/toolchain inputs,
  compiler failure, interrupted/failed preparation, checksum rejection, cache
  restoration, concurrent producers, conservative diff classification, final
  status propagation, release identity checks, and signing cleanup/preflight.
- The scoped portable and publication mise profiles were checked with global
  mise configuration disabled: portable resolves five tools, publication two.
  Native tooling cannot be installed by an omitted root configuration.

## Hosted validation and deliberate deferrals

The [first hosted implementation run](https://github.com/jeremytondo/atelier-next/actions/runs/34797562712)
passed: 342 seconds elapsed and 329 seconds total job execution. Its host
build took 231.6 seconds, Debug test invocation 72.4 seconds, Release helper
build 52.7 seconds, and assembly/probing 7.3 seconds. Helper compilation was
slower under concurrency but remained off the host-dominated critical path.
This cold run was slower than the audit's 272-second main Check; it is not
reported as a speedup. It included new coverage and cold tool/native caches.

The portable job completed in 25 seconds with JS test bodies/invocation at
0.106 seconds. Waiting for this entire job delayed the native job by 34
seconds. The task graph was then changed to run portable/native jobs together
after a small classification job. Cache hits also omit unnecessary repacking.
The initial native cache payloads were 7,305,461 and 714,960 bytes; save steps
took two and one seconds, respectively. Warm restore economics are measured
separately from this initial cache population.

[Attempt 2 of the same source](https://github.com/jeremytondo/atelier-next/actions/runs/34797562712/attempts/2)
passed in 116 seconds from rerun start (rerun queue time excluded), with 102
seconds of job execution. Both native receipts matched; no host or Release
helper compiler ran. Debug tests still ran for 34.2 seconds and the bundle
check for 7.0 seconds. Actions transferred 7,261,434 host bytes and 716,738
helper bytes, taking two seconds per restore step; extraction plus verification
took 1.50 and 1.09 seconds. This observed saving supports retaining the compact
output caches. It does not establish a median or p95.

The [revised parallel-job run](https://github.com/jeremytondo/atelier-next/actions/runs/34798401611)
also passed: 233 seconds elapsed, 241 seconds total job execution, with warm
tool caches but misses for both revised native input keys. Portable and native
jobs started five seconds apart after classification. The host build took
171.7 seconds, Debug test invocation 50.2 seconds, Release helpers 45.8 seconds,
and the bundle check 4.7 seconds. Compiler time also varied materially, so the
109-second reduction from the first implementation run cannot be attributed
entirely to scheduling. Subsequent diagnostics record CPU identity/count too.

## Manual branch dev release

[Run 34799685091](https://github.com/jeremytondo/atelier-next/actions/runs/34799685091)
published commit `624d96b8dad60d54c9700fcc6ed0dc337e4d1ea0` from
`ate-37-build-workflows`, without merging into `main`. Workflow elapsed was
326 seconds and total job execution was 314 seconds: packaging 298 seconds,
publication 16 seconds. The audited release took 520 seconds elapsed and 503
job seconds. This is one observation, not a controlled comparison or percentile.

No executable build caches were restored. Diagnostics show one host compilation
(209.7 seconds), Debug native tests (72.5 seconds), Release helpers (50.9 seconds),
and a bundle check (4.2 seconds). Distribution packaging then took 31.8 seconds,
including a 23.7-second notarization wait, and reused the gate's verified host
and helper outputs. Developer ID signing, full runtime/XPC and configuration
probes, notarization, stapling, and Gatekeeper all passed. Upload and download
of the release artifact took two seconds and one second respectively.

The published ZIP was 9,355,805 bytes. Downloaded ZIP/manifest checksums passed,
and the manifest's `source_ref`, source commit, and remote `dev` tag identified
the selected branch commit. PR checks also passed on that commit in
[run 34799676182](https://github.com/jeremytondo/atelier-next/actions/runs/34799676182).

The follow-up matrix above completes the scenario coverage and records the
limits of these comparisons. Future performance changes should retain the same
run/attempt identity, exact native inputs, cache state, and feedback timings.

Cross-workflow reuse of a passed gate (finding 7) remains deferred: releases
run the full gate and consume only their own verified native outputs. Icon
caching and targeted release-lookup optimizations remain deferred because their
measured opportunity is small. Dev planning now accepts shallow history while
stable planning still requires all tags. Local install/dev omit the unnecessary ZIP,
and release artifact uploads disable redundant compression; both notarization
and post-stapling ZIP passes remain intact.
