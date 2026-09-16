# Atelier configuration

Your configuration is `~/.config/atelier/init.js`, ordinary Hammerspoon 2 JavaScript with the full `hs` API. `atelier install` seeds it once; updates preserve it. If an existing file has no direct `require` of the installed Atelier package, interactive installation offers to back it up and replace it. Keeping the file is the default. Without an interactive terminal, installation warns and prints the import to add before `atelier.start(...)`, plus the recovery command. Edit it, then choose **Reload Config** from Hammerspoon 2's menu bar item. **Console** shows errors and lets you inspect the runtime; `hs.docs.show()` opens the HS2 API reference. Relative `require("./file.js")` paths resolve beside the requiring file, and `hs.loadSpoon` works as in stock Hammerspoon 2.

```js
const atelier = require("/opt/homebrew/share/atelier");

atelier.start({
  spaces: true,
  groups: true,
  overlay: true,
  overlayModifiers: "cmd-option",
  bindings: {
    "desktop-create": "ctrl-option-n",
    "select-1": "none",
  },
  quickApps: [
    {app: "Calculator", shortcut: "cmd-shift-c"},
    {app: "1Password", shortcut: "ctrl-option-p", size: {width: 900, height: 650}},
  ],
  groupPresets: [
    {name: "Dev", shortcut: "cmd-option-d", apps: ["T3 Code", "Ghostty", "Linear"]},
    {name: "Writing", apps: ["Obsidian", "Safari"]},
  ],
}).catch(console.error);

// Retain objects globally or in a module so HS2 does not collect active callbacks.
globalThis.terminalShortcut = hs.hotkey.bind(["cmd", "alt"], "t", () => {
  hs.application.launchOrFocus("com.apple.Terminal").catch(console.error);
}, null);
```

`require` returns the `atelier` object; there is no global. Every option is optional. `atelier.defaults()` returns a fresh copy of the shipped defaults. Omitted bindings inherit defaults; `"none"` disables one. `quickApps` replaces the whole default list; `[]` disables Quick Apps. `groupPresets` defaults to `[]`. `spaces: false` and `groups: false` disable those default shortcut sets; `groups: false` also leaves preset shortcuts and the picker unregistered. `overlay` and `overlayModifiers` control the Group list. Unknown options are errors and nothing starts.

You can omit `atelier.start()` entirely and use only your own HS2 automations, or use `atelier.spaces` and `atelier.application` from your own scripts without the defaults. Reload disposes the whole HS2 context, including your own hotkeys and tasks, and restarts the providers process.

## Recover a broken configuration

Run `atelier repair` to restore the shipped defaults and restart Hammerspoon 2. It first copies your existing `init.js` to a unique directory under `~/.config/atelier/backups/` and prints the exact backup path. If the backup fails, the original stays untouched. You can copy your customizations back from that file after confirming startup.

## What runs where

- **Hammerspoon 2** is the platform: it runs JavaScript and provides `hs.*`.
- **The defaults** are what `atelier.start` gives you: Groups, Desktop shortcuts, Quick Apps, and the overlay. They call `hs.*` and the API only.
- **The API** is the `atelier` object: functions shaped like HS2 modules that do not exist yet. `atelier.spaces` stands in for the missing `hs.spaces`; `atelier.application` fills two gaps in `hs.application`.
- **The providers** are one native binary, `atelier-providers`, started by the API as a child of Hammerspoon 2. It inherits the Accessibility grant you give Hammerspoon 2 and hosts one module per gap. When upstream gains an ability, the API function switches to `hs.*` and the provider goes away.

## Default actions

| Binding name | Default shortcut | Action |
| --- | --- | --- |
| `desktop-1` … `desktop-10` | Option–1 … Option–0 | Select ordinary Desktop on the focused window's display, pointer fallback |
| `desktop-create` | Option–grave | Create a Desktop at the end and enter it; one display, up to Desktop 16 |
| `desktop-left`, `desktop-right` | Control–Option–Left/Right | Reorder current Desktop |
| `desktop-delete` | Control–Option–Delete | Delete current Desktop; refuse the last Desktop |
| `group` | Command–Option–G | Create a Group on the current Desktop, or forget the one it has |
| `group-presets` | Command–Option–P | Open the Group preset picker; only registered when presets exist |
| `select-1` … `select-10` | Command–Option–1 … 0 | Select exact Group member |
| `cycle-previous`, `cycle-next` | Command–Option–[ / ] | Cycle Group members, including members beyond ten |
| `move-previous`, `move-next` | Command–Option–Shift–[ / ] | Move the focused member one position earlier or later |
| `move-1` … `move-10` | Command–Option–Shift–1 … 0 | Move the focused member to that position |
| `reload-config` | Control–Option–Command–R | Reload the complete configuration |

Hold Command–Option, optionally with Shift, to show the Group overlay; its chord can be changed separately from the bindings. The list shows app names, titles for duplicate apps, and the focused member, and it updates as you move a member. It does not take focus or intercept mouse clicks. Moving a member changes only the Group order; focus, placement, and Fill are unchanged, and the order is saved like any other Group change.

Shortcut strings accept cmd/command, option/alt/opt, ctrl/control, and shift, followed by a key. Examples: `cmd-shift-c`, `ctrl-option-space`, `option-grave`, `cmd-option-left-bracket`. Use `minus`, `equal`, `comma`, `period`, `slash`, `semicolon`, `quote`, or `backslash` where helpful. A shortcut used twice across the defaults, Quick Apps, and Group presets is a configuration error, as is an unknown option. A conflict with another application can prevent registration; resolve it and reload.

## Groups and Fill

Groups belong to a native display/Space pair. The `group` shortcut toggles: on a Desktop without a Group it creates one, recording the focused eligible window first and other eligible windows in deterministic inventory order; on a Desktop with a Group it forgets the Group, its numbering, and any slots still waiting for a preset app, leaving every window where it is. Only the selected/focused member receives native Fill; background members remain untouched until focused. Missing, minimized, hidden, fullscreen, modal, and Quick App windows are excluded. Arriving windows append to an existing Group, and a Group whose windows have all gone is forgotten.

Native Fill invokes Apple's menu action through HS2 Accessibility. Unsupported applications produce an error; Atelier does not silently substitute geometry resizing. Animation settles in the background so repeated selection remains responsive. A member whose Fill failed is left alone until the next reload.

Groups survive Reload Config and quitting Hammerspoon 2: their identities are saved to `~/Library/Application Support/Atelier/groups.json` within a second of each change and checked against the live windows on the next start. The `reload-config` shortcut and `atelier.stop()` save immediately; Reload Config or Quit from the Hammerspoon 2 menu can lose changes made in the last second. Deleting the file is safe. Failed Fills are retried after a reload. Groups do not survive a restart or logout: a saved Group is restored only if at least one of its windows still exists somewhere.

## Quick Apps

Each entry needs `app` and `shortcut`. App names, bundle IDs, and absolute `.app` paths are supported. Without a `size`, Atelier preserves smaller windows but limits larger ones to 1,000 × 720 points and 80% of the display's usable area. Optional `size` has positive width and height in points and overrides that floating-window limit; applications may enforce their own minimum size. Missing applications are reported and omitted while valid defaults continue.

A toggle launches or reopens the app quietly, unhides it, centers it on the originating display, pins it to every Desktop of that display, and focuses it. Toggling while it is frontmost hides the app and restores the remembered exact window if it still exists on the original active Desktop. Quick Apps stay excluded from Groups. All Desktops assignment can persist, and its Dock fallback may show a menu briefly. Undo the assignment through **Dock → Options → Assign To → None**. Removing a Quick App or quitting does not reverse that macOS setting. Fullscreen overlays, permanent always-on-top behavior, and moving windows between Spaces are unsupported.

## Group presets

A preset is a named, ordered list of apps written in `init.js`; Atelier saves nothing here. Each entry needs `name` and `apps`, and `shortcut` is optional. `apps` accepts the same app names, bundle IDs, and absolute `.app` paths as Quick Apps; the position in the list is the member number. A missing app is reported at startup and its entry is omitted while the rest of the preset still works. The same app twice in one preset, an app that is also a Quick App, a duplicate or empty name, and an unknown key are configuration errors. Presets share the Quick Apps limit of 50 entries.

Apply a preset with its shortcut, from the picker on `group-presets` (type to filter, Return applies, Escape closes), or with `atelier.groups.applyPreset("Dev")`. It needs an ordinary, empty Desktop: no window in the inventory, so hidden apps and Dock-minimized windows do not count. Anything else, including a fullscreen or Split View Desktop, refuses with a notification and Console line and changes nothing; the everyday flow is `desktop-create`, then the preset. For each app in order: a hidden app or minimized window that belongs to this Desktop is revealed without activation and takes its slot; an app that is not running or has no windows is launched or reopened quietly and its slot waits for the window to arrive; an app whose windows are all on other Desktops is left alone and its slot is reported empty, since Atelier does not move windows between Desktops.

Waiting slots give up after 30 seconds: the list closes the gap, later numbers shift down by one, and the Console names the app. Switching Desktops while slots wait means the window lands elsewhere and the slot times out. The overlay shows waiting slots dimmed with the app name, so the numbers are visible before every window has arrived. Focus goes to slot 1 only if its window is already here, with the usual Fill; arriving windows never take focus. Windows opened later append after the named slots. Applying never closes, hides, or moves a window, and `group` forgets a preset's Group like any other.

## The atelier object

Functions return promises unless noted. Overlapping default actions return `{busy: true}`.

- `atelier.start(options)`: start the defaults; a later call without options resumes with the previous ones. `atelier.stop()` synchronously releases owned bindings, observers, and timers and stops the providers.
- `atelier.status()`: synchronous runtime state, the last error, the package version, the running and expected Hammerspoon 2 build numbers, Quick Apps, Group presets with the apps that resolved, Group count, the Groups state file with its last save and restore result, and recent operation timings in milliseconds.
- `atelier.group()`: create a Group on the current Desktop or forget the one it has; resolves to the Group or `{forgotten: true}`. `atelier.space("switch", {number: 2})`, `atelier.space("create")`, `atelier.space("reorder", {offset: -1})`, `atelier.space("delete")`, `atelier.quickApp("Calculator")`.
- `atelier.groups.selectMember(2)`, `atelier.groups.cycleMember(-1)`, `atelier.groups.moveMember(-1)`, `atelier.groups.moveMember({slot: 1})`: the current Desktop's Group members by one-based slot. Member operations resolve to `{window: id}`, `{noop: true}` when there is no member to act on, or `{busy: true}`. A move takes a whole-number offset or `{slot: n}`; other values are errors. Selection counts waiting slots; cycling and moving act on the members that have arrived.
- `atelier.groups.applyPreset("Dev")`: apply a preset to the current empty Desktop; resolves to `{group, skipped}`, the Group with its `waiting` slots and the names of the apps whose slot was left empty, or `{busy: true}`.
- `atelier.spaces.snapshot()`, `atelier.spaces.membership(windowID)`, `atelier.spaces.switch({number})`, `atelier.spaces.create()`, `atelier.spaces.reorder({offset})`, `atelier.spaces.delete()`, `atelier.spaces.pin({pid, window, app, spaces})`: the Spaces provider, usable from your own modules. Prefer `atelier.space()` for mutations so shortcut coordination applies.
- `atelier.application.resolve("Calculator")` and `atelier.application.launch(path)`: resolve a name, bundle ID, or path to an app on disk; launch or reopen without activation.
- `atelier.providers.start()`, `atelier.providers.stop()`, `atelier.providers.running`: the providers process; the API starts it on first use.

Failed or timed-out provider mutations are never retried automatically: an action may already have completed. Inspect the Desktop before resuming. A providers failure stops the defaults and releases bindings; the Console remains available. Every installed file is type-declared: `hammerspoon.d.ts` for `hs.*` at the pinned revision and `index.d.ts` for the `atelier` object live beside the package in `/opt/homebrew/share/atelier`.

## Permissions, start-up, and diagnostics

On start the defaults compare Hammerspoon 2's build number with the pin and warn by notification and Console line on a mismatch; the defaults still start. If Accessibility is missing, startup waits and a setup dialog offers **Open Settings**. Enable Hammerspoon 2 under Privacy & Security → Accessibility (Device Control and Data Access on macOS 27); startup resumes automatically once both Hammerspoon and the providers can use Accessibility. Choosing **Later** dismisses the dialog. To reopen setup, run `atelier install`, which preserves your config and restarts Hammerspoon 2. If access is enabled but still not recognized, quit and reopen Hammerspoon 2. Stopping Atelier cancels the pending startup. Notification permission is requested after startup succeeds, once per context. A configuration error, a shortcut conflict, or a providers failure stops only the defaults; independent HS2 scripts keep running, and notifications and Console lines report the failure. Run `atelier install` to retry startup after fixing the cause. The Console logs **Atelier: Running** only after shortcuts are registered; launching Hammerspoon alone does not establish that Atelier started. Run `atelier doctor` from a terminal to check the installation, and `atelier.status()` in the Console for runtime detail.
