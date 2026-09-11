# Review evidence

The permission blockage below was subsequently resolved. See the
[native menu validation](../2026-09-10-menu-validation/README.md) for successful
native-state observations and the measured restoration discrepancy.

Environment: macOS 26.5.2, build 25F84, Apple silicon. Review performed September
10, 2026. Original source baseline: `db431b0`.

The text files contain fresh XcodeBuildMCP build/run transcripts, except the
WindowManager file, which contains the returned log-show excerpt.

| File | Invocation / meaning |
| --- | --- |
| [owned-left.txt](owned-left.txt) | `left --smoke-test`: owned-window positive control |
| [owned-left-windowmanager.txt](owned-left-windowmanager.txt) | System log corroborating native `leftHalf` tiled state for window 175686 (`0x2ae46`) |
| [foreign-transaction.txt](foreign-transaction.txt) | `left --cross-process-smoke-test`: fixture bounds remain unchanged |
| [independent-coordinator.txt](independent-coordinator.txt) | `left --coordinator-smoke-test --smoke-test`: owned-window bounds remain unchanged |
| [build.txt](build.txt) | Successful build after adding the menu probe and correcting bounds-result classifications |
| [menu-permission-block.txt](menu-permission-block.txt) | Final source compiles, then the menu probe exits before launch because Accessibility is unavailable |

The three behavioral controls ran before the final result-label/invalid-bounds
corrections; the corrected source subsequently compiled successfully.

The new menu probe was attempted through XcodeBuildMCP and directly as a binary.
Both attempts exited with Accessibility unavailable, before launching TextEdit.
The original diagnostic was misleadingly prefixed `Could not load SkyLight.framework`
because it reused a generic prototype error; that prefix has been corrected.
The actual condition is `AXIsProcessTrusted() == false`, not a framework-load
failure. This is an environment limitation, not a negative tiling result.
The runner labels the combined build/run failure as “Build failed”; the raw
transcript shows compilation and linking succeeded and the executable exited
at the permission guard.

The positive-control log was retrieved with:

```sh
/usr/bin/log show --last 8m --style compact --info --debug --predicate 'process == "WindowManager" AND (eventMessage CONTAINS "175686" OR eventMessage CONTAINS "Add Tiled Window")'
```

For a fresh experiment, start a narrowly filtered live log capture before the
action and retain its start/end times and target window ID. Do not require the
literal `clientRequest` reason for gesture-driven tiling; different native entry
paths may use a different reason. Absence of a log line alone is inconclusive.
