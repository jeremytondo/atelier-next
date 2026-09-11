# Desktop Groups prototype (ATE-14)

This process treats each opted-in macOS Desktop/display pair as an ordered,
Atelier-managed window stack. It is deliberately a prototype: state lasts only
while the process runs, there is no UI, and Fill uses the native Window menu
command on a best-effort basis.

## Build and run

From the repository root:

```sh
swift build --package-path Prototypes/NativeWindowTilingPOC
./desktop-groups --probe
./desktop-groups
```

The probe only resolves the private read APIs and prints the current Space ID
for each display. Running the manager requires Accessibility permission for the
responsible launcher (for example, Ghostty). To ask macOS to show the permission
prompt, use `./desktop-groups --request-accessibility` once, approve the launcher
in System Settings > Privacy & Security > Accessibility, then rerun it.

The process is an accessory application with no window or Dock icon. Keep the
terminal open and use Control-C to stop it. A per-user process lock rejects a
second manager before it can register observers or global hotkeys.

During initial smoke testing, this Mac experienced an Apple PCIe/Ethernet kernel
panic while two timed test launches had been left running. The evidence does not
support the prototype as its direct cause. The diagnosis and safer long-running
test procedure are in the
[incident review](Evidence/2026-09-10-mac-mini-panic/README.md).

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `Cmd-Opt-G` | Group or repair the Desktop containing the focused eligible window |
| `Cmd-Opt-1` … `Cmd-Opt-9` | Select members 1–9 |
| `Cmd-Opt-0` | Select member 10 |
| `Cmd-Opt-[` / `Cmd-Opt-]` | Select the previous / next member, wrapping at either end |

On first grouping, the focused window becomes member 1 and the rest follow in
Core Graphics front-to-back order. Initial Fill dispatch runs in reverse member
order so member 1 finishes focused. Running `Cmd-Opt-G` again repairs membership
and retries Fill; it does not dissolve the group.

New eligible windows append without focus theft. A background-created member is
left unfilled until first selected. Closed, minimized, hidden, fullscreen, moved,
or otherwise ineligible windows are removed and later indexes compact. Returning
windows append at the end. An AX observer drives prompt updates, with a one-second
reconciliation pass as a safety net.

## Architecture and boundaries

- `DesktopGroupsCore` owns ordered groups, active indexes, compaction, and each
  member's last Fill result. Its behavior is covered by Swift Testing tests.
- `DesktopGroupsPrototype` joins AX windows to Core Graphics window IDs only via
  `_AXUIElementGetWindow`; it has no ambiguous title/frame identity fallback.
- Read-only `SLSCopySpacesForWindows` and `SLSCopyManagedDisplaySpaces` calls
  identify the native Space and display. A window returned on anything other
  than exactly one Space is excluded, which rejects All Desktops windows.
- Eligibility requires an on-screen layer-zero `AXStandardWindow` whose position
  and size are settable. Atelier's process, hidden apps, minimized/fullscreen
  windows, dialogs, sheets, and utility panels are excluded.
- `NativeMenuDispatch` is the ATE-13 semantic menu dispatcher extracted as a
  shared target. Fill invokes `_zoomFill:` through `AXPress`; it never assigns an
  AX frame. Missing, disabled, or failed commands update state and do not remove
  a member or stop the batch.
- Selection sets the exact window's `AXMain` value, raises it, and activates only
  its application—never `activateAllWindows`.

The private symbols and native menu identifier can change in a macOS update.
The prototype fails explicitly if its required identity/Space symbols disappear.
SkyLight may not report off-Space membership; inactive groups are therefore held
unchanged and reconciled when their Space is active again.

## Native multi-Fill experiment

Use two unrelated, single-window apps on one Desktop, then repeat with two
windows from one app:

1. Give the windows distinct original sizes and press `Cmd-Opt-G` on the first.
2. Confirm both remain independently Fill-sized after the initial reverse pass.
3. Alternate `Cmd-Opt-1` and `Cmd-Opt-2`; after the first selection has settled,
   subsequent unchanged selections should not dispatch another Fill.
4. Use the native Return to Previous Size command on each window and inspect
   WindowManager logs to determine whether macOS retained independent restore
   state.
5. Manually resize one member, select the other, then select the resized member.
   Only the resized member should receive a fresh Fill attempt.

Indexed focus and membership remain valid even if macOS retains native Fill
state for only the most recently filled window.
