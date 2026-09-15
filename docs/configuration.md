# Atelier configuration

Your configuration is `~/.config/atelier/init.js`, ordinary Hammerspoon 2 JavaScript with the full `hs` API. `atelier install` seeds it once and never touches it again; Atelier updates never overwrite it. Edit it, then choose **Reload Config** from Hammerspoon 2's menu bar item. **Console** shows errors and lets you inspect the runtime; `hs.docs.show()` opens the HS2 API reference. Relative `require("./file.js")` paths resolve beside the requiring file, and `hs.loadSpoon` works as in stock Hammerspoon 2.

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
}).catch(console.error);

// Retain objects globally or in a module so HS2 does not collect active callbacks.
globalThis.terminalShortcut = hs.hotkey.bind(["cmd", "alt"], "t", () => {
  hs.application.launchOrFocus("com.apple.Terminal").catch(console.error);
}, null);
```

`require` returns the `atelier` object; there is no global. Every option is optional. `atelier.defaults()` returns a fresh copy of the shipped defaults. Omitted bindings inherit defaults; `"none"` disables one. `quickApps` replaces the whole default list; `[]` disables Quick Apps. `spaces: false` and `groups: false` disable those default shortcut sets. `overlay` and `overlayModifiers` control the Group list. Unknown options are errors and nothing starts.

You can omit `atelier.start()` entirely and use only your own HS2 automations, or use `atelier.spaces` and `atelier.application` from your own scripts without the defaults. Reload disposes the whole HS2 context, including your own hotkeys and tasks, and restarts the providers process.

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
| `group` | Command–Option–G | Create or repair Group on current Desktop |
| `select-1` … `select-10` | Command–Option–1 … 0 | Select exact Group member |
| `cycle-previous`, `cycle-next` | Command–Option–[ / ] | Cycle Group members, including members beyond ten |
| `reload-config` | Control–Option–Command–R | Reload the complete configuration |

Hold Command–Option to show the Group overlay. Its modifier chord can be changed separately from selection bindings. The list shows app names, titles for duplicate apps, and the focused member. It does not take focus or intercept mouse clicks.

Shortcut strings accept cmd/command, option/alt/opt, ctrl/control, and shift, followed by a key. Examples: `cmd-shift-c`, `ctrl-option-space`, `option-grave`, `cmd-option-left-bracket`. Use `minus`, `equal`, `comma`, `period`, `slash`, `semicolon`, `quote`, or `backslash` where helpful. Duplicate default/Quick App shortcuts and unknown options are configuration errors. A conflict with another application can prevent registration; resolve it and reload.

## Groups and Fill

Groups belong to a native display/Space pair. Creating a Group records the focused eligible window first and other eligible windows in deterministic inventory order. Only the selected/focused member receives native Fill; background members remain untouched until focused. Missing, minimized, hidden, fullscreen, modal, and Quick App windows are excluded. Arriving windows append to an existing Group.

Native Fill invokes Apple's menu action through HS2 Accessibility. Unsupported applications produce an error; Atelier does not silently substitute geometry resizing. Animation settles in the background so repeated selection remains responsive. Repair the Group to retry a member whose Fill previously failed. Group identities are session-only: Reload Config resets them.

## Quick Apps

Each entry needs `app` and `shortcut`. App names, bundle IDs, and absolute `.app` paths are supported. Optional `size` has positive width and height in points; applications may enforce their own minimum size. Missing applications are reported and omitted while valid defaults continue.

A toggle launches or reopens the app quietly, unhides it, centers it on the originating display, pins it to every Desktop of that display, and focuses it. Toggling while it is frontmost hides the app and restores the remembered exact window if it still exists on the original active Desktop. Quick Apps stay excluded from Groups. All Desktops assignment can persist, and its Dock fallback may show a menu briefly. Undo the assignment through **Dock → Options → Assign To → None**. Removing a Quick App or quitting does not reverse that macOS setting. Fullscreen overlays, permanent always-on-top behavior, and moving windows between Spaces are unsupported.

## The atelier object

Functions return promises unless noted. Overlapping default actions return `{busy: true}`.

- `atelier.start(options)`: start the defaults; a later call without options resumes with the previous ones. `atelier.stop()` synchronously releases owned bindings, observers, and timers and stops the providers.
- `atelier.status()`: synchronous runtime state, the last error, the package version, the running and expected Hammerspoon 2 build numbers, Quick Apps, Group count, and recent operation timings in milliseconds.
- `atelier.group()`, `atelier.select(2)`, `atelier.cycle(-1)`, `atelier.space("switch", {number: 2})`, `atelier.space("create")`, `atelier.space("reorder", {offset: -1})`, `atelier.space("delete")`, `atelier.quickApp("Calculator")`.
- `atelier.spaces.snapshot()`, `atelier.spaces.membership(windowID)`, `atelier.spaces.switch({number})`, `atelier.spaces.create()`, `atelier.spaces.reorder({offset})`, `atelier.spaces.delete()`, `atelier.spaces.pin({pid, window, app, spaces})`: the Spaces provider, usable from your own modules. Prefer `atelier.space()` for mutations so shortcut coordination applies.
- `atelier.application.resolve("Calculator")` and `atelier.application.launch(path)`: resolve a name, bundle ID, or path to an app on disk; launch or reopen without activation.
- `atelier.providers.start()`, `atelier.providers.stop()`, `atelier.providers.running`: the providers process; the API starts it on first use.

Failed or timed-out provider mutations are never retried automatically: an action may already have completed. Inspect the Desktop before resuming. A providers failure stops the defaults and releases bindings; the Console remains available. Every installed file is type-declared: `hammerspoon.d.ts` for `hs.*` at the pinned revision and `index.d.ts` for the `atelier` object live beside the package in `/opt/homebrew/share/atelier`.

## Permissions, start-up, and diagnostics

On start the defaults compare Hammerspoon 2's build number with the pin and warn by notification and Console line on a mismatch; the defaults still start. If Accessibility is missing they ask macOS for it, notify, and stop; grant access to Hammerspoon 2 in System Settings, then Reload Config. They request notification permission once per context, since `hs.notify.show` does not ask itself. A configuration error, a shortcut conflict, or a providers failure stops only the defaults; independent HS2 scripts keep running, and the failure is shown as a notification naming what failed plus a Console line. Run `atelier doctor` from a terminal to check the installation, and `atelier.status()` in the Console for runtime detail.
