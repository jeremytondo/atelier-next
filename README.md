# Atelier Next

Atelier is a customizable macOS workspace built on [Hammerspoon 2](https://github.com/cmsj/Hammerspoon2) (HS2) 

## Install and use

```sh
curl -fsSL https://raw.githubusercontent.com/jeremytondo/atelier-next/main/install/install.sh | bash
```

That installs the `atelier` and pinned `hammerspoon2` casks from `jeremytondo/atelier` by their full names, allowing Homebrew to trust those packages, and runs `atelier install`. The `atelier` command quits Hammerspoon 2 if it is running, points it at `~/.config/atelier/init.js`, seeds that file once, adds Hammerspoon 2 to Login Items, and starts it. Grant Accessibility access through **Open Settings** when asked; startup resumes automatically after access is available. If an existing config cannot load Atelier, installation warns and offers recovery. `atelier repair` backs up that file and restores the shipped defaults. `atelier doctor` checks an installation and prints what to fix; `atelier uninstall` undoes the settings and login item and leaves the init file. The [dev install command](docs/releases.md#install-update-and-switch-channels) installs `atelier@dev` with its own `hammerspoon2@dev` dependency. Each channel becomes available with its first published release. See [releases](docs/releases.md) for updates and switching channels.

Your config is ordinary HS2 JavaScript with the full `hs` API. It requires the installed package and calls `atelier.start({...})`; the [configuration reference](docs/configuration.md) covers the options, default shortcuts, window lists, Quick Apps, presets, and the `atelier` API. Hammerspoon 2's own menu bar item provides Reload Config and the Console.

## Layout

- `api/`: the `atelier` object. Functions shaped like HS2 modules that do not exist yet (`atelier.spaces`, `atelier.application`) and the pipe to the providers process.
- `defaults/`: the features `atelier.start` gives you, written against `hs.*` and the API.
- `providers/`: the Swift package for `atelier-providers`, one binary hosting a module per missing HS2 capability.
- `cli/`: the `atelier` command. `install/`: the one-line installer and the seeded init file. `tests/`: TypeScript tests run by Node.
- `hammerspoon2.json`: the Hammerspoon 2 pin. Tests, the type fetch, the runtime build check, HS2 builds, and release packaging read it.

## Build and check

Install Xcode and mise, then run `mise install`. `mise tasks` lists the entry points and `scripts/build-package.sh --help` the packaging options. `mise run dev` builds the package and copies it into the Homebrew prefix; choose Reload Config in Hammerspoon 2 afterwards. `mise run check` is the gate CI runs, and `mise run format` applies the formatters that `mise run lint` enforces. TypeScript is compiled by `tsc` against upstream's generated `hammerspoon.d.ts` for the pinned revision; treat an upstream type error as a prompt to check real behaviour, since the declarations are generated from doc comments.

## Hammerspoon 2 dependency

Atelier runs on an unpatched Hammerspoon 2 installation. `hammerspoon2.json` selects the exact source commit and records its source checksum and the app build number Atelier expects at startup.

When `release` names an upstream release, Homebrew downloads that official ZIP. When `release` is `null`, release CI publishes or reuses an Atelier-built snapshot of the selected source. Snapshots are signed and notarized; installing them requires no source checkout, mise, or Xcode.

For local development, quit Hammerspoon 2 and run `mise run hs2:install` to build the selected source and replace the installed app, saving a backup. A different running HS2 build triggers a Console warning and an attempted notification; Atelier continues running.

See [releases](docs/releases.md#hammerspoon-2-builds) for snapshot reuse and dependency upgrades.

## Reference source

`mise run refs` downloads a research checkout into `repos/hammerspoon2` at the selected commit, leaving an existing checkout unchanged. This directory is gitignored and never used by builds.

- `mise run refs:update` aligns it with `hammerspoon2.json`, refusing local edits or commits.
- `mise run refs:status` shows its revision and whether it matches the pin.

Fetching newer upstream code for research does not change Atelier's dependency.

## Manual trial

Use disposable Desktops and saved windows for Desktop switching, create, reorder, and delete; numbered selection of visible, hidden, and minimized windows, cycling from a window and from nothing listed, and reordering; a window with an open sheet or dialog, an All Desktops window on two Desktops, a window moved between Desktops, and a fullscreen round trip; presets from a shortcut and the picker, with an app hidden, minimized, and open on another Desktop; the held-modifier overlay with and without Shift, including dimmed hidden windows and waiting slots; and Quick Apps. With two displays, check that the shortcuts follow the Desktop that has keyboard focus. Verify reload during a Space operation, that window order returns after Reload Config and after quitting and reopening Hammerspoon 2 but not after a logout, the Accessibility and notification prompts, and `atelier doctor` on a healthy and a broken install. Desktop creation uses macOS's window-management bridge without opening Mission Control and supports one display; reorder and delete still use Mission Control. HS2 remains experimental; upgrades require explicit behaviour verification.
