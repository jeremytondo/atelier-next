# Native creation control after Space 168

The user manually added one Desktop using Mission Control's + button and
reported that it appeared normally. Mission Control showed two Desktops,
not three. This supplements the earlier
[registration diagnosis](2026-09-14-registration-diagnosis.md).

The read-only diagnostic at **2026-09-14 12:57:56 UTC** found:

| Observation | Result |
| --- | --- |
| WindowServer order | `3, 176, 168` |
| Current Space | `176`, the newly added native Desktop |
| Original experimental ID and UUID | `168`, `432996B4-BAD7-410B-A47E-18950F94CFB1`, unchanged |
| New native ID and UUID | `176`, `6E2BCADE-7D76-4F74-BB6E-A9340F733AB9` |
| Saved Desktop configuration | **Now contains `3, 176, 168`** |
| Per-Space values | All three expose only `id64`, `ManagedSpaceID`, `type`, `uuid`; all type 0 |
| Display identifier | `BF1BDA7D-2A5B-41FB-933D-405802D73ED3`, unchanged |
| User-observed Mission Control count | Two |

A subsequent on-disk plist read also contained all three IDs and Space
Properties entries for all three UUIDs. This corrects the earlier snapshot's
limited implication: **persisting the experimental Space does not make it
visible in Mission Control**. The earlier omission from preferences was not
sufficient to identify the missing registration step.

The normal Desktop was inserted before `168`, rather than replacing it. Native
creation and entry worked in this display environment. Adding that Desktop did
not cause Mission Control to expose the experimental entry. A general inability
of this session to create or show native Desktops is therefore not the cause.
This does not rule out a virtual-display-specific interaction with WMBridge.

Further static inspection supports a distinction between Dock's live model and
the WindowServer records. On this build, `Spaces.allUserSpaces` traverses Dock's
display storage; the helper at `0x10028366C` filters the display's object array
at offset `0x38` using the objects' `userSpace` methods. `ManagedSpace.userSpace`
at `0x1001DF448` returns true directly. This path is not just a query of the
four fields exposed by SpaceCopyValues. Dock's initialization region also has
a path that reads the WindowServer census and rebuilds its display storage
(`0x1001E4F04` followed by resetting the model array at `0x1001E4F34`).

The leading explanation is that the experiment allocated a Space without
adding the corresponding object to Dock's live Desktop model. This is an
inference from the behavior and inspected code, not a direct inspection of
Dock's memory. Neither a fresh census nor presence in saved preferences is a
valid proxy for successful registration. A working third-party call that
completes that registration with SIP enabled remains unidentified.

Raw report:
`.build/ate-40-manual/trial-36rXDA/diagnose-1789390676899-3759af9e-583b-46b1-ab2e-754717db8456.json`.
The comparison used the existing diagnostic without code changes. No creation,
switching, cleanup, preference writes, or Dock restart was issued by the agent
during this comparison. Both `168` and the user's native Desktop `176` were
left in place. In particular, `176` is not owned by the experiment's cleanup
journal and must not be treated as an automatically disposable resource.
