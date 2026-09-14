# ATE-37 build workflow measurements

These are individual observations from September 13, 2026 (America/Chicago),
not median or p95 claims. The issue's hosted baseline and this developer Mac
have different CPU capacity and cache state; their durations are not directly
comparable. The implementation is in the mise tasks, workflows, and scripts;
[release documentation](releases.md) describes operation and state locations.

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
caches. Their hosted transfer economics still need the measurements below;
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

Before claiming the issue's performance completion criteria, measure cold
native, repeated warm, JS-only, docs-only, and manual dev-release workflows.
Retain run URLs, `ci:report` JSON, diagnostic artifacts, compressed cache bytes,
restore/save step durations, and the first relevant test completion timestamp.
Repeat comparable cases before drawing conclusions about variation. The full
release trial requires this implementation on trusted `main` and an explicit
manual release dispatch; local signing is not a notarization/publication trial.

Cross-workflow reuse of a passed gate (finding 7) remains deferred: releases
run the full gate and consume only their own verified native outputs. Icon
caching and targeted release-lookup optimizations remain deferred because their
measured opportunity is small. Dev planning now accepts shallow history while
stable planning still requires all tags. Local install/dev omit the unnecessary ZIP,
and release artifact uploads disable redundant compression; both notarization
and post-stapling ZIP passes remain intact.
