# Atelier configuration

Atelier reads `~/.config/atelier/config.toml` at launch. If `XDG_CONFIG_HOME` is an absolute path in the app's launch environment, it uses `$XDG_CONFIG_HOME/atelier/config.toml` instead. An environment variable set only inside a terminal may not reach an app launched from Finder.

**Saving a file does not reload it.** Choose **Reload Configuration** in Atelier's menu, or press **Control–Option–Command–R**. Change or disable that shortcut in `[bindings]`. Pause/Resume uses the already loaded configuration; it does not reread files. The reload shortcut remains available while paused. Reloading while paused keeps Atelier paused.

Atelier never rewrites your configuration after creating or migrating the initial file. Comments, formatting, and symlinks belong to you. Runtime state is stored separately.

## Start with one file

```toml
# ~/.config/atelier/config.toml
version = 1
spaces = true
groups = true
overlay = true
overlay-modifiers = "cmd-option"
launch-at-login = false

[bindings]
reload-config = "ctrl-option-cmd-r"
# desktop-delete = "none"

[quickapps.calculator]
app = "Calculator"
shortcut = "cmd-shift-c"

# [quickapps.notes]
# app = "/Applications/Your Notes App.app"
# shortcut = "ctrl-option-n"
# size = [900, 650]
```

All settings are optional. Omitted feature options default to `true`; the overlay chord defaults to `cmd-option`. `version`, when present, must be `1`. Omitting `launch-at-login` leaves the macOS registration unchanged. Setting it explicitly requests that state. macOS may still require approval under Login Items; Atelier reports the actual status.

`groups` controls Groups and native Fill on focus. `spaces` controls Desktop shortcuts. `overlay` controls the Group list. `overlay-modifiers` accepts one or more of `cmd`, `option`, `ctrl`, and `shift`, joined by hyphens. The list appears when exactly those modifiers are held. Caps Lock does not affect the chord.

## Split files when useful

```text
~/.config/atelier/
  config.toml
  keybindings.toml
  quickapps.toml
```

```toml
# config.toml — put include before any [table].
include = ["keybindings.toml", "quickapps.toml"]
overlay = true
```

```toml
# keybindings.toml
[bindings]
reload-config = "ctrl-option-cmd-r"
```

```toml
# quickapps.toml
[quickapps.calculator]
app = "com.apple.calculator"
shortcut = "cmd-shift-c"
```

Relative includes resolve from the file containing the include. Absolute and `~/` paths also work. Included files load in listed order, then the containing file applies its own settings. Later values override earlier values. Each named Quick App is replaced as a **whole entry**, so an override must provide `app` and `shortcut` again. Different names accumulate. A single reload applies the complete tree.

Includes are explicit and required. Missing files, cycles (including symlink cycles), unknown options, invalid values, and duplicate active shortcuts reject the reload. The limits are 8 nested include levels, 32 file visits, 256 KiB per file, and 1 MiB total. Configuration files contain TOML data; JavaScript, Lua, shell commands, environment interpolation, and scripting hooks are not evaluated.

## Keybindings

Bindings map action names to shortcut strings. Omitted actions keep their defaults; `"none"` disables a binding. Feature switches also release that feature's bindings. Reload is independent of the feature switches.

| Action | Default |
| --- | --- |
| `reload-config` | `ctrl-option-cmd-r` |
| `desktop-1` … `desktop-9` | `option-1` … `option-9` |
| `desktop-10` | `option-0` |
| `desktop-create` | `option-grave` |
| `desktop-left` / `desktop-right` | `ctrl-option-left` / `ctrl-option-right` |
| `desktop-delete` | `ctrl-option-delete` |
| `group` | `cmd-option-g` |
| `select-1` … `select-9` | `cmd-option-1` … `cmd-option-9` |
| `select-10` | `cmd-option-0` |
| `cycle-previous` / `cycle-next` | `cmd-option-left-bracket` / `cmd-option-right-bracket` |

At least one modifier is required. Modifier aliases include `command`, `control`, `alt`, and `opt`. Keys include letters, digits, `left`, `right`, `up`, `down`, `return`, `tab`, `space`, `escape`, `delete` (Backspace), `forwarddelete`, `home`, `end`, `pageup`, `pagedown`, and `f1`…`f20`. Punctuation names include `grave`, `minus`, `equal`, `comma`, `period`, `slash`, `semicolon`, `quote`, `backslash`, `left-bracket`, and `right-bracket`.

Shortcuts currently use macOS physical ANSI key positions. Non-US keyboard layout translation is not implemented. macOS does not expose every shortcut another application may intercept.

## Quick Apps

Each `[quickapps.name]` entry has a stable name you choose, such as `calculator` or `notes`. No UUIDs or numeric keycodes are needed.

- `app` (required): application name, bundle identifier, or absolute/`~/` `.app` path. Bundle identifiers are usually the most portable choice between Macs.
- `shortcut` (required): the global toggle shortcut.
- `size` (optional): `[width, height]` in points; both must be finite and positive. Sizes are clamped to the display, and apps may enforce minimum sizes.
- `enabled` (optional, default `true`): set `false` to retain an entry without activating it.

Press the shortcut to launch/reopen, unhide, center, and focus the app on the current display. Press it while that app is frontmost to hide it and restore the previous exact window when available. Minimized windows are restored. Quick Apps stay out of Groups and Fill. Renaming an entry changes its configuration identity; the engine's remembered app/window state is preserved through reload.

All Desktops assignment is automatic. The Dock fallback can keep that assignment after an entry is removed; undo it through **Dock → Options → Assign To → None**. Removing an entry releases its binding and Group exclusion; it does not quit or hide the app.

## Validation and reload failures

The app validates TOML, types, unknown keys, sizes, actions, and shortcut conflicts before applying a reload. It then resolves enabled Quick Apps and acquires new global shortcuts before releasing old registrations. A rejected reload leaves the previous working configuration, engine, Groups, and shortcuts active. The menu shows **View Issue…**, with the file and line for syntax errors or the setting path for value errors. Fix the files and explicitly reload again.

Reload waits for an active window operation to finish. It never restarts the engine or retries a window mutation. A runtime change during that wait cancels the reload; use the menu to try again once Atelier is ready. Launch-at-login approval/failures are reported separately because macOS owns that registration.

On a fresh launch, malformed configuration leaves window operations paused until you fix and reload it. An unavailable Quick App is reported while other valid features can start. A reload is stricter: any unavailable enabled Quick App rejects the entire proposed update. Disable machine-specific entries with `enabled = false` when they aren't installed.

For a read-only file check in a terminal:

```sh
/Applications/Atelier.app/Contents/MacOS/Atelier --validate-config
/Applications/Atelier.app/Contents/MacOS/Atelier --validate-config /path/to/config.toml
/Applications/Atelier.app/Contents/MacOS/Atelier --config-path
```

Validation exits nonzero on errors and does not launch another app, request Accessibility, migrate files, resolve installed applications, or reserve global shortcuts. Runtime availability is checked by the running app when you reload.

## Hammerspoon and migration

The standalone app does not run Hammerspoon, JavaScript, or Lua. Keep unrelated Hammerspoon configuration where that installation already reads it. This project's Hammerspoon 2 prototype uses `~/.config/hammerspoon2/`; Atelier uses `~/.config/atelier/`. Files under `Prototypes/Hammerspoon2/` in the repository remain a reference implementation and are not installed app resources.

When `config.toml` does not yet exist, Atelier migrates `~/Library/Application Support/Atelier/settings.json` if present. Otherwise it can import literal Quick App entries from `~/.config/hammerspoon2/quickapps.js`. It preserves the source files, never executes them, and stops with an error if they cannot be translated. Existing TOML always wins, including when it contains errors. After migration, changes to either legacy source have no effect on Atelier.

The prototype's Atelier loader was disabled during the standalone installation handoff. Keep only one Atelier runtime active to avoid overlapping hotkeys. Other Hammerspoon automations can continue independently.

Configuration is suitable for your dotfiles. Live Groups/window identities, `status.json`, and shortcut recovery data stay in `~/Library/Application Support/Atelier/`; logs stay in `~/Library/Logs/Atelier/`. Groups are currently in memory only and reset when Atelier quits. The old `settings.json` is retained for rollback to the earlier local build; new TOML edits are not copied back into it.
