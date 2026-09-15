# Atelier configuration

Atelier provides Hammerspoon 2 with optional workspace defaults. Your configuration runs as JavaScript with the full `hs` API. Open it from the Atelier menu, save changes in your editor, then choose **Reload Config**. Use **Open Console** for errors and interactive inspection. The bundled HS2 API reference is available through `hs.docs.show()`.

The entry point is `~/.config/atelier/init.js`, honoring an absolute `XDG_CONFIG_HOME`. An absolute `ATELIER_CONFIG_DIR` overrides the directory for isolated development and tests. Relative `require("./file.js")` paths resolve beside the requiring module, and `hs.loadSpoon` is supported; Finder installation of `.spoon2` bundles is not. User files are never overwritten by app updates.

`atelier.start(options)` is Atelier's stable configuration contract. Direct `hs` scripting is supported, with APIs that follow the selected upstream HS2 revision and may change on upgrade.

```js
const options = {
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
  // launchAtLogin: true,
};
atelier.start(options).catch(console.error);

// Retain objects globally or in a module so HS2 does not collect active callbacks.
globalThis.terminalShortcut = hs.hotkey.bind(["cmd", "alt"], "t", () => {
  hs.application.launchOrFocus("com.apple.Terminal").catch(console.error);
}, null);
```

Every option is optional. `atelier.defaults()` returns a fresh copy of the shipped defaults. Omitted bindings inherit defaults; `"none"` disables one. `quickApps` replaces the whole default list; `[]` disables Quick Apps. `spaces: false` and `groups: false` disable those default shortcut sets. `overlay` and `overlayModifiers` control the Group list. `launchAtLogin` accepts true/false; omitting it preserves the existing login registration. Install Atelier in Applications before enabling it, and approve it in System Settings → Login Items if requested.

You can omit `atelier.start()` entirely and use only your own HS2 automations. The Atelier object is supplied by the application bootstrap; `hs` remains available directly. Reload disposes the entire old HS2 context in process, including custom hotkeys and tasks, and retains Console logs. Pause/Resume Atelier Defaults only affects objects owned by `atelier`. To apply changed options, reload or stop before calling `atelier.start(newOptions)`.

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

Shortcut strings accept cmd/command, option/alt/opt, ctrl/control, and shift, followed by a key. Examples: `cmd-shift-c`, `ctrl-option-space`, `option-grave`, `cmd-option-left-bracket`. Use `minus`, `equal`, `comma`, `period`, `slash`, `semicolon`, `quote`, or `backslash` where helpful. Duplicate default/Quick App shortcuts and unknown options are configuration errors. A conflict with another application can prevent registration; resolve it and reload using the menu.

## Groups and Fill

Groups belong to a native display/Space pair. Creating a Group records the focused eligible window first and other eligible windows in deterministic inventory order. Only the selected/focused member receives native Fill; background members remain untouched until focused. Missing, minimized, hidden, fullscreen, modal, and Quick App windows are excluded. Arriving windows append to an existing Group.

Native Fill invokes Apple's menu action through HS2 Accessibility. Unsupported applications produce an error; Atelier does not silently substitute geometry resizing. Animation settles in the background so repeated selection remains responsive. Repair the Group to retry a member whose Fill previously failed. Group identities are session-only: Pause retains them; Reload Config and Quit reset them.

## Quick Apps

Each entry needs `app` and `shortcut`. App names, bundle IDs, and absolute `.app` paths are supported. Optional `size` has positive width and height in points; applications may enforce their own minimum size. Missing applications are reported and omitted while valid defaults continue.

A toggle launches/reopens, unhides, centers, and focuses the configured app on the originating display. Toggling while it is frontmost hides the app and restores the remembered exact window if it still exists on the original active Desktop. Quick Apps stay excluded from Groups. All Desktops assignment can persist, and its Dock fallback may show a menu briefly. Undo the assignment through **Dock → Options → Assign To → None**. Removing a Quick App or quitting does not reverse that macOS setting. Fullscreen overlays, permanent always-on-top behavior, and moving windows between Spaces are unsupported.

## Modules and helpers

The following return promises unless indicated otherwise:

- `atelier.start(options)` / `atelier.ready`: start defaults and await startup.
- `atelier.stop()`: synchronously release owned bindings, observers, and timers and request helper termination.
- `atelier.group()`, `atelier.select(2)`, `atelier.cycle(-1)`.
- `atelier.space("switch", {number: 2})`, `atelier.space("create")`, `atelier.space("reorder", {offset: -1})`, `atelier.space("delete")`.
- `atelier.quickApp("Calculator")`.
- `atelier.status()`: synchronous runtime state, errors, version, Quick Apps, Group count, and recent operation timings.
- `atelier.native("snapshot")` / `atelier.native("membership", {window: ID})`: access native topology/membership gaps from your own modules. Prefer `atelier.space()` and `atelier.quickApp()` for mutations so their targeting and shortcut coordination apply.

Overlapping default actions return `{busy: true}`. Failed/timed-out helper mutations are never retried automatically: an action may already have completed. Inspect the Desktop before resuming. Helper failure stops the defaults and releases bindings; the menu and HS2 Console remain available.

## First launch, recovery, and diagnostics

The native welcome screen appears before your first configuration execution. Grant Accessibility, or choose **Continue Without Access**. Defaults report missing access while independent scripts can run. After granting access later, choose **Accessibility Help** to check permission and reload automatically.

A running Hammerspoon copy produces a startup conflict warning, with **Continue Anyway**, **Quit Atelier**, and **Don't warn again**. An installed but stopped copy is informational. When switching fully to Atelier, disable the other app's login item and consider uninstalling it; Atelier never changes another app's configuration or quits it.

Existing `init.js` always wins, including empty or invalid files. If absent, Atelier copies the current bundled default file once. It does not import configuration from earlier formats.

A synchronous configuration exception keeps objects created before the failure active. A syntax error loads nothing. The error stays in the menu and Console; fix the file and choose **Reload Config**. Invalid defaults options, missing Accessibility, shortcut conflicts, and helper failures stop only Atelier Defaults. If the previous helper will not stop within the bounded shutdown period, reload reports an error and leaves that context available for another attempt. Closing native windows leaves Atelier running in the menu bar.

Use **Export Diagnostics** to save runtime status and recent timings, plus native status, errors, and version information even when the context is unavailable. The default export excludes window titles. The HS2 Console may contain information printed by your own scripts.
