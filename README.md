# Atelier Next

Atelier is a customizable macOS workspace built on [Hammerspoon 2](https://github.com/cmsj/Hammerspoon2) (HS2): Desktop shortcuts, window Groups with native Fill, Quick Apps, and a Group overlay, for Apple silicon Macs running macOS 27.

## Install and use

```sh
curl -fsSL https://raw.githubusercontent.com/jeremytondo/atelier-next/main/install/install.sh | bash
```

That taps `jeremytondo/atelier` and installs the `atelier` cask, which pulls the pinned `hammerspoon2` cask and runs `atelier install`. The `atelier` command points Hammerspoon 2 at `~/.config/atelier/init.js`, seeds that file once, adds Hammerspoon 2 to Login Items, and starts it. Grant Accessibility access to Hammerspoon 2 when asked. `atelier doctor` checks an installation and prints what to fix; `atelier uninstall` undoes the settings and login item and leaves the init file. `brew install --cask atelier@dev` follows the newest dev release instead. The casks are published once Hammerspoon 2 ships the release the pin needs; see [releases](docs/releases.md).

Your config is ordinary HS2 JavaScript with the full `hs` API. It requires the installed package and calls `atelier.start({...})`; the [configuration reference](docs/configuration.md) covers the options, default shortcuts, Groups, Quick Apps, and the `atelier` API. Hammerspoon 2's own menu bar item provides Reload Config and the Console.

## Layout

- `api/`: the `atelier` object. Functions shaped like HS2 modules that do not exist yet (`atelier.spaces`, `atelier.application`) and the pipe to the providers process.
- `defaults/`: the features `atelier.start` gives you, written against `hs.*` and the API.
- `providers/`: the Swift package for `atelier-providers`, one binary hosting a module per missing HS2 capability.
- `cli/`: the `atelier` command. `install/`: the one-line installer and the seeded init file. `tests/`: TypeScript tests run by Node.
- `hammerspoon2.json`: the Hammerspoon 2 pin. Tests, the type fetch, the runtime build check, the dev-only HS2 build, and cask generation read it.

## Build and check

Install Xcode and mise, then run `mise install`. `mise tasks` lists the entry points and `scripts/build-package.sh --help` the packaging options. `mise run dev` builds the package and copies it into the Homebrew prefix; choose Reload Config in Hammerspoon 2 afterwards. `mise run check` is the gate CI runs, and `mise run format` applies the formatters that `mise run lint` enforces. TypeScript is compiled by `tsc` against upstream's generated `hammerspoon.d.ts` for the pinned revision; treat an upstream type error as a prompt to check real behaviour, since the declarations are generated from doc comments.

## Hammerspoon 2 dependency

`hammerspoon2.json` names the upstream revision and source checksum, the `CFBundleVersion` build number Atelier is tested against, and, once one exists, the upstream release tag and ZIP checksum the `hammerspoon2` cask installs. Only the build number identifies an HS2 release: the 0.0.12 ZIP reports version 1.2 and build 133. While the pin is ahead of the newest upstream release, `release` stays `null`, the casks are not published, and development runs against `mise run hs2:install`, a stock build of the pinned revision stamped with the pinned build number. That interim build number is upstream's last release number plus a suffix, so it can never be mistaken for a real release. Upgrading HS2 means changing the pin, running the checks, using it for a day, and releasing. The defaults warn by notification and Console line when the running build differs from the pin, and keep running.

`mise run refs` creates a shallow checkout of Hammerspoon 2 under `repos/hammerspoon2` for research only; it is gitignored and never a build input. `mise run refs:update` fast-forwards it to upstream `main`, refusing local edits; `mise run refs:status` shows its state.

## Manual trial

Use disposable Desktops and saved windows for Desktop switching, create, reorder, and delete; Groups, exact window selection, and native Fill; the held-modifier overlay; and Quick Apps. Verify reload during a Space operation, the Accessibility and notification prompts, and `atelier doctor` on a healthy and a broken install. Desktop creation uses macOS's window-management bridge without opening Mission Control and supports one display; reorder and delete still use Mission Control. HS2 remains experimental; upgrades require explicit behaviour verification.
