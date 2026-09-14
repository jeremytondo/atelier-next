# ATE-40: a real display refresh makes the omitted Desktop usable

New evidence on macOS 26.5.2 (25F84), SIP enabled, September 14, 2026.
This supplements [the earlier activation trials](2026-09-14-activation-and-dock-refresh.md).

The user changed Jump Desktop's scaling and restored it. Mission Control then
showed **three Desktops**, including the previously omitted Space **168**.
Subsequent bounded trials entered 168 through its Mission Control thumbnail and
through the native next-Desktop shortcut, displayed a saved test window, and
typed successfully. The resolution change is a proven repair for visibility and
those entry paths on this session. It is not a completed no-flash creation method.

## The same Space survived the refresh

Before and after, WindowServer reported `[3,176,168]`, with 176 current. The
created Space retained UUID `432996B4-BAD7-410B-A47E-18950F94CFB1`. No additional
Space was created or destroyed during these follow-ups. Desktop 176 is the
user-created native control and remains intact.

The independent `CoreDockGetWorkspacesCount` query changed from **2** to **3**:

| Read-only diagnosis in `.build/ate-40-manual/trial-36rXDA/` | Observation |
| --- | --- |
| `diagnose-1789392693948-521304f8-a6d6-453c-8832-8c886f885b64.json` | Before: Dock 2, WindowServer 3, source mode 90, logical 1600×1000. |
| `diagnose-1789392978239-0200145a-5bc2-428d-9af3-c596ee4cf4b3.json` | During manual change: Dock 3, same Space IDs/UUIDs, source mode 117, logical 2048×1280. |
| `diagnose-1789393595197-e84034ae-854c-449b-abb1-fb484929dde1.json` | After restoration: Dock 3, source mode 90, logical 1600×1000. |
| `diagnose-1789394046740-f77cca0e-a46e-4a4e-9bb6-577a480b4698.json` | Dock 3 persists; both displays at their original modes and 60 Hz. Default mode enumeration exposes no alternative with identical logical and pixel dimensions. |

Jump Desktop display 27 remained the main, active mirror source. Physical
display 3 remained its inactive mirror, mode 55. The final topology agrees with
the original mirror relationship. Dock remained PID 424 throughout.

`.build/ate-40-diagnosis/dock-real-refresh.log` records actual display callbacks
on Dock at 08:36:07.995–08:36:08.071 local time, including
`Entering handleDisplayReconfig()`. A second cycle occurred at 08:36:23.929–.932
when the user restored scaling. This exercises the handler identified in the
earlier static analysis. The unchanged-configuration trials had emitted no
callbacks and had not exercised it.

Apple describes the public callback sequence as a begin notification for online
displays followed by callbacks describing their changed configuration.
[Quartz display notification documentation](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/Notification.html).
Our observation of Dock's model repair comes from the local counts, logs, and
GUI trials, not from that public contract.

## Native entry and typing

Each follow-up below is a private child of the original outer trial directory.
The original creation journal authorizes only ID 168 with its recorded UUID.
Completed trials returned to 176 and retained all three Space IDs in order.

| Trial | Result |
| --- | --- |
| `select-native-restore` | AX press on Desktop 3's native thumbnail returned success; current became 168. Fixture window 3879 was visible, on its active Space, and saved the typed phrase. Returned through Desktop 2's native thumbnail. |
| `adjacent-settled` | Posted the existing, enabled next-Desktop binding, symbolic action 81, without first opening Mission Control. Current became 168; fixture 3916 was visible, on its active Space, and saved the typed phrase. Returned through Desktop 2's native thumbnail. |
| `native-control-after-refresh` | The actual Atelier engine switched 176→3 and 3→176 successfully, approximately 383 and 337 ms including verification. Its numbered shortcut to 168 timed out after 3 seconds. The final snapshot remained on 176. |

The successful saved files contain `ATE40 verified typing`. Fixture-start to
typed/saved was approximately 149 ms for thumbnail entry and 146 ms for adjacent
entry. These figures exclude the preceding switch and are not end-to-end
creation or navigation latency. All fixture windows closed; these tests opened
Mission Control for observation/restoration and do not establish visual silence.

### Harness limitations exposed during follow-up

- `select-after-refresh` entered 168 but its typing failed. A subsequent normal
  176 control observed inherited event flags `0x20040000`, which include Control.
  Plain-text fixture events now explicitly clear modifiers; the normal control
  and both final 168 tests pass. The earlier failed typing is not reliable
  evidence of an unusable Desktop.
- The initial adjacent trial hardcoded Control+Right instead of reading its
  native binding, which also includes the secondary-Fn flag. A later trial used
  the exact binding but still opened/closed Mission Control immediately before
  input and observed only 400 ms afterward. `adjacent-settled` removes that
  preceding overview and allows up to 3 seconds for the destination. It succeeds;
  these changes do not isolate animation suppression from observation timing.
- The first native-entry trials restored only WindowServer's current ID using
  WMBridge. That is insufficient evidence that Dock's current object agrees.
  A repeated thumbnail selection then failed despite AX success. Native trials
  now restore through a native thumbnail; successful known-Desktop switching
  preceded the final checks. Earlier restoration claims establish only their
  recorded census equality, not complete agreement between the two processes.

## What remains unresolved

The numbered-shortcut failure has a separate concrete lead. Local arm64e Dock
function `0x100007870` reads `allUserSpaces`, then registers/removes numbered
hotkeys according to its count. Native add (`0x1001F083C`) and remove
(`0x1001F0F64`) call it through `0x100119FE8`; the display-rebuild path inspected
earlier does not call that routine. Live bindings 118–120 all have valid
Control+number values and are normally disabled; the engine temporarily enables
them and restores them. The 1/2 positive control makes the failure specific to
the third route in this trial. Missing Dock-side registration is an inference
from these observations, not yet a tested repair.

No invisible creation-time model-refresh trigger has been demonstrated:

- Empty and identical-mode transactions already failed to produce callbacks.
- No same-geometry alternative was exposed in the current default mode list.
- `CoreDockSendNotification` dispatch on this build recognizes overview,
  show-desktop and launcher commands, not an arbitrary model-refresh selector.
- WindowServer's `__CGXPostNotificationToConnection` checks caller privileges
  before delivery. Its client stub is asynchronous; a successful send would
  not prove acceptance. No guessed display payload or privileged notification
  was posted.
- A newly found [ShiftPlus implementation report](https://shiftplus.app/blog/macos-spaces-without-disabling-sip/)
  describes synthetic Dock swipes to repaint after switching existing Spaces.
  It supplies another coordination lead, but does not demonstrate creation or
  registration of an omitted Desktop. Its swipe sequence was not run here.

The next discriminating tests are whether a normal Dock add/remove cycle
refreshes the third shortcut registration, and whether an externally callable
coordination path can rebuild Dock's model without changing the display mode.
Neither is established by the resolution workaround. Production creation
behavior remains unchanged.

## Final checks

`mise run wmbridge:test` passed 5 Swift and 13 Node tests. Native commands were
built and run through XcodeBuildMCP. A fresh read-only probe at 13:56:12 UTC
confirmed current 176, IDs `[3,176,168]`, and that successful fixture windows
3879 and 3916 were absent after helper exit. Space 168 is intentionally left
available for manual testing. The three ordinary Desktops remain in place.
