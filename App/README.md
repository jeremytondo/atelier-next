# Atelier

Atelier is a configurable Hammerspoon 2 distribution for Apple silicon Macs running macOS 26. It ships one `Atelier.app` containing HS2, Atelier's JavaScript defaults, and native helpers for missing Space and Quick App capabilities. Installed use requires no separate Hammerspoon, Node, Python, Xcode, or repository checkout.

## Install and use

Download the [dev ZIP](https://github.com/jeremytondo/atelier-next/releases/download/dev/Atelier-macos-arm64.zip), unzip it, quit the previous Atelier, and move `Atelier.app` into `/Applications`. Open Atelier, complete onboarding, and grant **Atelier** Accessibility access using its menu. After granting access, choose **Reload Config**. Keep only one copy of Atelier active and disable any old Atelier loader in a separate HS2 installation before using the same shortcuts.

The menu shows the defaults' runtime state and recent error. It provides Open Configuration, Reload Config, the HS2 Console, Pause/Resume Atelier Defaults, Export Diagnostics, and a link to releases. Pause stops Atelier's own defaults; independent HS2 automations in your config continue. Reload Config releases the complete old HS2 context and loads your configuration again. Groups survive Pause/Resume but reset on reload or quit.

## Customize

The entry point is `~/.config/atelier/init.js` (or `$XDG_CONFIG_HOME/atelier/init.js`). Settings can select a different configuration file. Use `atelier.start({...})` to customize the bundled defaults, `require("./my-module.js")` to split your configuration, and `hs` directly for your own automations. Omitted options receive defaults; a binding set to `"none"` is disabled. See the bundled [configuration reference](Resources/Configuration.md).

The app seeds `init.js` once. If an earlier Atelier `config.toml` exists, it imports those settings, including includes, shortcuts and Quick Apps. Otherwise it can import the earlier `settings.json` or literal prototype Quick Apps. Existing JavaScript always wins. Legacy sources remain untouched and are no longer read once `init.js` exists. Invalid legacy data produces an error instead of silently substituting defaults. App updates preserve user files.

## Build and check

Use the repository's mise tasks; see [release documentation](../docs/releases.md) and `scripts/build-app.sh --help`. `mise run build` emits a locally signed app and ZIP. `mise run check` builds the HS2 host, runs native and JavaScript tests, and checks release automation. Packaging additionally probes the real bundled HS2 engine and configuration preservation in a private temporary directory. Release packaging requires Developer ID signing, notarization, stapling, and Gatekeeper validation.

The production dependency is pinned in [upstream.json](Hammerspoon/upstream.json). `scripts/prepare-hammerspoon.sh` verifies the source archive and applies [the integration patch](Hammerspoon/atelier.patch) in `.build/hammerspoon2`. Its dependency lockfile remains pinned. `repos/` and `Prototypes/` are independent research material and never build inputs. The patch supplies Atelier identity, configuration/bootstrap hooks, reload cleanup, and manual release controls; it removes upstream's unused Sparkle updater.

Native helpers and one-time configuration migration live in `Sources/`; runtime policy lives in `Resources/Atelier/`. [The host integration](Hammerspoon/AtelierHost.swift) supplies app-specific paths, status, and login registration while retaining HS2's engine, console, settings, onboarding, and automation modules.

## Manual alpha trial

Test on disposable Desktops and saved windows first. Verify Desktop switching/create/reorder/delete; Groups, exact window selection and Fill; held-modifier overlay; Calculator summon/hide and focus return. Edit a binding and add a direct HS2 automation, reload repeatedly, pause/resume, and confirm no duplicate actions. Replace the app with a newer build and verify your config survives. Check permission denial/revocation, sleep/wake, multiple displays, and the apps you use daily.

Window movement between Spaces, fullscreen overlays, persistent Groups, and guaranteed always-on-top foreign windows remain unsupported. Quick Apps use All Desktops assignment, which can persist after stopping Atelier; undo it through Dock → Options → Assign To → None. Space lifecycle operations use Mission Control and retain native animations. The numbered native shortcut route supports up to 16 global ordinary Desktops; default bindings expose ten on the target display. HS2 remains experimental; the pinned version is deliberately updated and validated separately.
