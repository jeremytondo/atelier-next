# Why Space 168 is missing from Mission Control

The user's manual trial reproduces a persistent disagreement between
WindowServer's Space list and Mission Control. The leading explanation on this
build is missing Dock registration. This investigation identifies the relevant
code paths; it does not establish a working registration operation.

## Manual observation and read-only comparison

The user ran `mise run desktop:create` at 2026-09-14 12:44:52 UTC and reported
that Mission Control still showed just one Desktop. The returned ID was `168`.
The native journal records exactly one addition to `[3]`, resulting in `[3, 168]`,
with `3` still current. The created ID's UUID is
`432996B4-BAD7-410B-A47E-18950F94CFB1`. Creation preserved the focused window and
pointer. Some existing all-Spaces memberships gained the new ID; complete
membership invariance is not claimed.

Environment: macOS 26.5.2 (25F84), SIP enabled, unlocked console session, one
Jump Desktop virtual display (1600 × 1000 logical, 2×), display UUID
`BF1BDA7D-2A5B-41FB-933D-405802D73ED3`.

At 12:54:10 UTC, a new process still read `[3, 168]`, with `3` current. Thus the
entry survived the creator's exit and more than nine minutes of elapsed time.
Both the bridge and direct census agreed. `SLSBridgedSpaceCopyValuesOperation`
returned exactly the same set of keys for `3` and `168`: `id64`, `ManagedSpaceID`,
`type`, and `uuid`. Both had type 0. No extra missing metadata key was exposed
by this read.

The `SpacesDisplayConfiguration` preference, read through CFPreferences without
synchronization or writes, contained only `3` in its saved `Spaces` arrays.
A separate read of the on-disk plist also contained only `3`. Saved preferences
can lag live state; this supports the discrepancy but is not an authoritative
read of Dock's current in-memory list.

Raw evidence remains private and gitignored in:

- `.build/ate-40-manual/trial-36rXDA/creation/`: original intent, dispatch, result.
- `.build/ate-40-manual/trial-36rXDA/diagnose-1789390450452-4b85c1e3-c6fe-49b9-a0bf-a3eee66b5ef9.json`:
  independent census, per-Space values, read-delegate trace, saved configuration.
- `.build/ate-40-diagnosis/`: local system disassembly and reference source used
  for inspection only.

## What the local implementation does

Read-only `dyld_info -disassemble` inspection on this build establishes:

1. AppKit's `NSWMWindowCoordinator` synchronous bridge method at `0x1858F29F4`
   forwards the operation to its client manager. A temporary, forwarding trace
   of a **read** observed both `NSWMWindowCoordinator` and `WMClientWindowManager`
   returning the expected property-list result; the process-local fallback
   delegate was not invoked.
2. `WMClientWindowManager` in WindowManagement.framework obtains `_serverProxy`
   and calls `performSynchronousBridgedWindowManagementOperation:replyHandler:`
   at `0x27C2BD66C`.
3. WindowManager.app's `AppKitApplicationConnection` handler at `0x1000A90C4`
   selects the thunk at `0x1000A9004`. That thunk calls `invokeFallback` at
   `0x1000A9018` and returns the result through the reply handler.
4. SkyLight's `SLSBridgedSpaceCreateOperation.invokeFallback` at `0x186EDF588`
   calls `SLSWindowServerClientSpaceCreate` at `0x186EDF5A8`, then wraps the
   returned ID in the Space-ID result object. The underlying creation function
   serializes the values and sends a Mach request to WindowServer.

The live system log corroborates the service connection during the original
manual run: WindowManager activated a connection from `wmbridge-experiment`
PID 90564 at 07:44:52.900 local time and invalidated it at 07:44:52.998. The
earlier probe had its own connection, PID 90232.

This is a working AppKit bridge forwarding low-level operations through the
WindowManager service. It is not evidence of a special high-level Desktop
creation implementation inside that service. The runtime trace above is of a
read, not a replay of the user's create; the creation route is inferred from
the inspected dispatch implementations and corroborating connection log.

Dock has its own `ManagedSpace` objects and per-display arrays. Its
`allUserSpaces` implementation at `0x1001EA168` traverses its display models.
The Dock routine at `0x100285564` inserts a managed object into a display's
array, calls `CGSMoveManagedSpaceToDisplayIndex` at `0x10028569C`, and calls
its wallpaper manager's `addSpace:forDisplayUUID:` at `0x1002856EC`.
Those steps are additional to the low-level allocation. Their presence does
not prove a third-party caller can invoke them without injection, nor that
calling the reorder operation alone would register a Desktop with Dock.

Relevant arm64e binary UUIDs:

- WindowManagement.framework: `080939D0-13CF-3107-87BA-F58B7CCB2C51`.
- WindowManager.app: `BAF1B3B5-D2F9-3AE5-B809-E12886739797`.
- Dock.app: `5DF5CC12-1875-3DEA-9DF7-48A3F8BEF94D`.

## Reference comparison and remaining questions

The creation sequence matches the pinned
[Native Space Kit implementation](https://github.com/Fjx-dylanZ/native-space-kit/blob/01b7e49718d500ed08add3e95533e2b9b41b2561/src/native_space_kit.m#L370):
unsigned options 0, empty values, synchronous bridge dispatch, exact returned
64-bit ID, and a type-0 census check. Its separate activation operation uses
show/hide/set-current, and its Mission Control consistency claim appears in
the reorder findings. The report does not isolate Mission Control visibility
immediately after allocation from the effects of later activation/reordering.
It reports a different OS build, macOS 27 RC 26A428.

[KiwiDesk PR 990](https://github.com/KiwiCanopy/KiwiDesk/pull/990) describes a
create/rename/stamp/destroy census round trip on 26.6.1. Its described
switch-to-current check does not establish entry into the newly created Space.
These reports remain leads, not proof that our local behavior must be a bad ABI.

The next discriminating control is a Desktop added manually through Mission
Control's + button while `168` remains present. Compare what the user sees with
the fresh census and saved configuration. If the new native Desktop appears
but `168` stays omitted, that weighs against a general Mission Control/display
failure and toward a separate Dock registration requirement. If `168` appears
as well, investigate the refresh/notification triggered by native creation.
This is a diagnostic control, not a creation fallback for Atelier.

No creation, switching, window movement, cleanup, preference writes, or Dock
restart was performed during this diagnosis. Space `168` remains in place for
the user's manual follow-up. No production default changed. `mise run
wmbridge:test` passed 5 Swift and 13 Node tests; the new diagnostic ran live
without a mutation. Historical findings remain unchanged.
