**Native Desktop creation — September 13, 2026**

The follow-up discussion requires real macOS Desktops, fully enabled System
Integrity Protection, and no Mission Control flash from normal Atelier actions.
The user prefers a compact keyboard panel and ideally wants no visible Mission
Control preparation step either. Native macOS commands must remain available.

No creation mechanism reviewed so far satisfies all of those requirements and
preferences. Shortening the Mission Control sequence cannot meet zero flash;
Dock injection is ruled out by the SIP requirement. Pre-created Desktops remain
a candidate, but their initial provisioning and replenishment are unresolved.
The earlier recommendation to optimize the visible creation sequence is
superseded by these constraints.

This is research, not an implementation decision or a performance benchmark.
The user explicitly requires real macOS Desktops. No Desktop/window mutations,
app launches, preference changes, or security-setting changes were performed.

**What makes the current implementation slow**

The production [bridge](../App/Sources/AtelierEngine/EngineBridge.swift) calls
`createDesktop`, then `enterActiveDesktop`. The shared
[Mission Control implementation](../App/Sources/AtelierEngine/MissionControl.swift)
still prepares an expanded, stable overview before and after creation:

| Step in the usual path, starting with Mission Control closed | Explicit settling interval |
| --- | --- |
| Open Mission Control and let its entrance finish | 350 ms |
| Move the pointer to the display's top edge and stabilize the current thumbnail | 250 ms |
| Press Add; verify exactly one new ordinary Desktop; stabilize its thumbnail | 250 ms |
| Activate it through the native numbered shortcut; expand and stabilize again | 250 ms |
| Stabilize its thumbnail again before pressing it to enter | 250 ms |
| Verify Mission Control remains absent | 200 ms |

That is about **1.55 seconds of serial settling intervals**, excluding additional
animation, topology changes, AX calls, and polling overhead. This is derived from
the source, not measured latency; already-open Mission Control and other branches
can differ. Several checks each start a fresh 250-ms stability window even if
the previous check established the same thumbnail was stable.

The historical [Space Control findings](../Prototypes/NativeWindowTilingPOC/SPACE-CONTROL.md)
deliberately favored a visible overview and leaving it open for keyboard
navigation. Production now immediately closes it. The user's feedback is reason
to revisit that presentation choice. Preserve the historical findings and change
the production creation flow independently of interactive reorder/delete needs.

**macOS 26 and 27**

The development Mac reports macOS **26.5.2, build 25F84**. Apple currently lists
26.6.2, build 25G83, and macOS **27 RC, build 26A428**, released September 9.
The latter is the next-version research target; neither 26.6.2 nor 27 was tested
on this machine. [Apple releases](https://developer.apple.com/news/releases/)

Apple's documented Desktop creation still goes through Mission Control's Add
button. Its public `NSWorkspace` and `NSWindow.CollectionBehavior` references
offer notifications and behavior for application windows, but I found no
ordinary-Desktop creation API there. The 27 RC release notes contain Mission
Control fixes and expanded tiling eligibility, but no documented replacement for
this operation. This is a bounded search finding, not proof that every private
mechanism has been exhausted. [Apple's Spaces guide](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac),
[NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace),
[window collection behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct),
[27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)

I also inspected the installed Dock executable, rather than relying only on API
documentation. It contains `createSpaces`, `spacesCount`, and an internal
`com.apple.dock.ppt` service. The nearby connection-validation path requires the
`com.apple.private.dock.ppt` entitlement and checks the code identifier against
`com.apple.DockPPT`; failure cancels the XPC connection. This points to an Apple
internal route, not a usable third-party API.

Reproducible evidence from
`/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock`:

- SHA-256: `9ff944ab8969c5bd2ef94880550f4df0b7c41416b7303353b7fce5ca3fe475fd`.
- `strings` exposes the command, service, entitlement, and rejection messages.
- `otool -arch arm64e -tvV` shows the entitlement string at `0x10027e504`, a
  check at `0x10027e520`, and rejection branch at `0x10027e534`.
- The helper calls through `0x100311368` to `0x10030ca3c`, which invokes
  `SecTaskCopyValueForEntitlement` at `0x10030ca68` and checks a Boolean result.
- The code-identifier comparison references `com.apple.DockPPT` at
  `0x10027e5d8`; rejection calls `xpc_connection_cancel` at `0x10027e618`.
- The creation-message handler references `spacesCount` at `0x10027e9a0` and
  logs a missing-count error at `0x10027ea5c`.

These are static observations and interpretation of one OS build. I did not
invoke the service, establish its complete protocol, or examine a macOS 27 Dock
binary. Presence of a creation command alone does not establish caller access.

**What Hammerspoon and other tools actually provide**

| Tool or mechanism | Native Desktops? | Finding for Atelier |
| --- | --- | --- |
| Hammerspoon 2 | Yes, through Atelier's helper today | Refreshed upstream `main` at `c0bd4d6ecfcb30b426b5b12a4292a95ad418f8ad` has no `hs.spaces` module or Desktop creation API. Its AX and timer APIs can coordinate an improved sequence. Atelier pins 0.0.12 at `7a218ddfc3c6c49246bff3e538c9c46e29a59caf`. |
| Hammerspoon 1 `hs.spaces` | Yes | Opens Mission Control, finds `mc.spaces.add`, presses it, and optionally closes the overview. Creation does not require our pointer expansion or repeated thumbnail waits. Useful prior art, not a tested timing guarantee on this Mac. |
| Yabai | Yes | Creation calls its scripting addition, which constructs a Dock `ManagedSpace` and invokes Dock's internal add function. Requires partially disabled SIP. |
| BetterTouchTool | Yes | Its author's published explanation says its Add Space action opens Mission Control and presses Plus. This explanation is from 2018, not a current-binary audit. |
| InstantSpaceSwitcher / Yabai gesture switching | Yes | Can accelerate switching among existing Spaces. Does not establish a creation mechanism. |
| SpaceCommand | Yes | Its native backend enumerates Spaces and posts numbered shortcuts; its other backend delegates to Yabai. No new creation route established. |
| AeroSpace | No | Emulates workspaces by moving inactive windows offscreen. Outside the user's requirement. |
| FlashSpace | No | Primarily hides/shows applications; deliberately does not split individual windows of one app across workspaces. Outside the user's requirement. |
| TotalSpaces2 | Yes historically | Discontinued; vendor says Apple Silicon is unsupported. Not a current foundation. |

Sources: [HS2 source](https://github.com/cmsj/Hammerspoon2/tree/c0bd4d6ecfcb30b426b5b12a4292a95ad418f8ad/Hammerspoon%202/Modules),
[Hammerspoon 1 creation source](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/spaces.lua#L675),
[Hammerspoon Spaces documentation](https://www.hammerspoon.org/docs/hs.spaces.html#addSpaceToScreen),
[Yabai creation dispatch](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L1062),
[Yabai Dock implementation](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m#L542),
[Yabai SIP requirements](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection),
[BetterTouchTool author explanation](https://community.folivora.ai/t/shortcut-for-adding-a-desktop-space/5189/2),
[Yabai gesture implementation](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L926),
[SpaceCommand](https://github.com/ZimengXiong/SpaceCommand),
[AeroSpace design](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces),
[FlashSpace design](https://github.com/wojciech-kulik/FlashSpace#-no-support-for-individual-app-windows-per-workspace),
[TotalSpaces2 status](https://totalspaces.binaryage.com/documentation2).

Avoid outdated generalizations about Yabai: its changelog records Space focusing
with SIP enabled in 7.1.19, improvements to animation skipping in 7.1.21–23, and
window movement with SIP enabled again in 7.1.25. **Creation remains a separate
scripting-addition operation.** Its current source also carries an unreleased
fix for the add-Space signature on 26.6. A contributor reports 27 beta support
with changed add-Space patterns, but that June beta report does not establish
27 RC compatibility. [Yabai changelog](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md),
[27 beta report](https://github.com/asmvik/yabai/issues/2802)

Old `CGSSpaceCreate` examples are another misleading lead. A low-level Space
object is not evidence of a correctly registered ordinary Desktop with Dock's
display ordering and lifecycle. The old Hammerspoon extension that offered
direct creation is explicitly unmaintained; it documented Dock resets and broken
multi-display creation even on 10.11. It is historical evidence, not a validated
route for 26/27. [Old extension](https://github.com/asmagill/hs._asm.undocumented.spaces)

**Direction after the follow-up discussion**

The compact keyboard panel can be designed around existing native Desktops:
select a Desktop, inspect its Group, and reflect changes made through native
commands. The native topology should remain authoritative. A custom panel does
not itself grant additional creation, deletion, or reordering capabilities.

A full-screen covering interface was also considered. Apple documents that
`stationary` windows remain visible during Mission Control, and ThreeFingerSwitcher
places its panel above the overview with a screen-saver window level. Neither
source establishes flash-free Desktop creation under a covering interface.
The user prefers a compact panel, so an opaque full-screen overview is not the
chosen direction. [Apple stationary behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary),
[overlay source](https://github.com/amitayks/ThreeFingerSwitcher/blob/be3e480b3dcf1db01672d616f72190c330ec7fa0/Sources/ThreeFingerSwitcher/Overlay/OverlayController.swift#L34)

The remaining feasibility question is narrowly defined: can Atelier register a
new ordinary Desktop with Dock while SIP stays fully enabled, without exposing
Mission Control or relying on a full-screen covering interface? A candidate
must preserve native switching, ordering, display association, and window
membership. A returned low-level Space ID alone is insufficient. No such
candidate has been validated; this is not proof that none exists.

If that investigation does not establish a route, a reserve requires an explicit
product compromise about provisioning. The user's preference against visible
preparation is recorded as a preference, not approval for an exception. The
following reserve rules are proposals, not an accepted design:

- A reserve consists of real Desktops explicitly designated for reuse. It remains
  visible in Mission Control and reachable through normal native navigation.
- Native creation, deletion, reordering, and use of a reserved Desktop must be
  reconciled. Atelier must not silently recreate a Desktop the user deleted.
- Reserve exhaustion cannot fall back to opening Mission Control. Existing
  Desktops remain usable, but new allocation needs available capacity.
- Releasing a verified empty Desktop for reuse is different from deleting a
  native Desktop. Native deletion can move windows to another Desktop; recycling
  must not imply that behavior or close applications.
- A separate Atelier-only order would disagree with native left/right navigation;
  prefer native ordering unless the user explicitly chooses that difference.

The current inventory uses `.optionOnScreenOnly` and excludes hidden applications,
minimized windows, and several other window classes. It cannot establish that an
inactive Desktop is empty. The current background observation also depends on
Groups being present and has no independent native Space lifecycle event path.
Reserve ownership and occupancy therefore need dedicated evidence and
reconciliation, rather than reuse of Group membership as an emptiness test.
[Native inventory](../App/Sources/AtelierEngine/EngineBridge.swift),
[observation](../App/Resources/Atelier/index.js),
[Group scope](../App/Resources/Atelier/groups.js)

Prefer HS2 JavaScript for configurable policy and asynchronous orchestration.
Reuse the existing native topology and switching boundary; extend it only for
capabilities HS2 lacks. Do not port the entire helper into JS just to reduce a
delay, and do not ship changes to the upstream HS2 pin merely for this research.

For any future creation experiment, record input-to-new-ID, overview-visible duration,
input-to-active-ID, input-to-ready-for-typing, pointer displacement, and failures.
Use a monotonic clock and compare the existing flow with the candidate on
disposable Desktops and saved test windows. Check one and multiple displays,
fullscreen adjacency, already-open Mission Control, repeated shortcuts, Reduce
Motion on/off, and both 26 and 27 when available. Do not lower waits without
checking actual resulting Space IDs and focus.

An accepted AX press followed by a timeout is an uncertain mutation, not proof
that nothing happened. Reconcile topology before any retry to avoid duplicate
Desktops; report a created ID even if later activation fails. Reserve handling
would additionally need session-scoped ownership, fresh occupancy checks,
invalidation after topology changes, and the existing global numbered-shortcut
limit. An apparently empty user Desktop is not automatically an Atelier reserve.

The immediate recommendation is to resolve creation feasibility separately from
the panel design. Do not adopt a reserve or a reduced-flash fallback as though it
already satisfies the user's zero-flash requirement. No application behavior was
changed during this discussion.
