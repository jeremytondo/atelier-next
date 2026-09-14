# Atelier

Atelier is a customizable macOS workspace for Apple silicon Macs running macOS 27. One menu-bar app owns the native interface and runs Hammerspoon 2's JavaScript engine, APIs, and Console in process. Its bundled native helper supplies Space and Quick App capabilities in a separate process. Installed use requires no separate Hammerspoon, Node, Xcode, or repository checkout.

## Install and use

Download the [dev ZIP](https://github.com/jeremytondo/atelier-next/releases/download/dev/Atelier-macos-arm64.zip), unzip it, quit the previous Atelier, and move `Atelier.app` into `/Applications`. The welcome screen appears before configuration execution. Grant Accessibility or choose **Continue Without Access**. If you grant permission later, choose **Accessibility Help**; it checks access and reloads configuration when granted.

Atelier warns at startup if Hammerspoon or HS2 is running. Continue Anyway and Don't warn again support deliberate coexistence. When switching fully to Atelier, disable the other app's startup/login behavior and consider uninstalling it. Atelier never changes another app's configuration or quits it.

The menu provides status and errors, Open Configuration, Configuration Reference, Reload Config, Pause/Resume Atelier Defaults, Console, Export Diagnostics, permissions help, releases, and Quit. Native windows focus normally; closing them leaves Atelier running without a persistent Dock icon. Behavior is configured in JavaScript.

## Customize and recover

The entry point is `~/.config/atelier/init.js`, honoring an absolute `XDG_CONFIG_HOME`. For isolated development, set an absolute `ATELIER_CONFIG_DIR`. Atelier seeds current bundled defaults only when `init.js` is absent. Empty, invalid, and customized files are preserved. Normal startup ignores legacy configurations and stale HS2 path preferences.

`atelier.start({...})` is the stable Atelier options contract. Relative `require("./my-module.js")`, file-based extensions, `hs.loadSpoon`, and direct `hs` scripting are supported. Direct HS2 APIs follow the selected upstream revision and may change on upgrade. See the bundled [configuration reference](Resources/Configuration.md), including the JavaScript launch-at-login option. Finder installation of `.spoon2` bundles is not provided.

A synchronous configuration exception preserves objects created before the error. The menu and Console show the error; correct the file and reload to recover. Defaults startup failures clean up only Atelier Defaults. Pause/Resume likewise preserves independent scripts. Reload replaces the entire JS context in process; Groups reset on reload and persist across Pause/Resume. If the old helper cannot stop safely, reload refuses replacement and reports a recoverable error. Console logs and native diagnostics remain available.

## Build and check

Use the repository's mise tasks and `scripts/build-app.sh --help`; see [releases](../docs/releases.md). `mise run build` emits a locally signed app and ZIP; `dev` and `install` omit the ZIP. `mise run check` runs native and JS tests, checks release automation, and assembles an ad-hoc bundle for isolated probes. AppleScript/XPC verification requires Apple signing and runs in signed packaging. Publication remains manual.

[The HS2 integration guide](Hammerspoon/README.md) explains the exact dependency pin, source reconstruction, compatibility shims, and upgrade gate. `repos/` is independent research material and never a build input. Runtime policy lives in `Resources/Atelier/`; native shell source lives in `Hammerspoon/Shell/` and `Hammerspoon/ShellCore/`; native helpers live in `Sources/`.

## Manual trial

Use disposable Desktops and saved windows for Desktop switching/create/reorder/delete, Groups, exact window selection and native Fill, the held-modifier overlay, and Quick Apps. Verify custom scripts, repeated reloads, and Pause/Resume. Permission and coexistence checks require a disposable environment. Check sleep/wake and multiple displays before relying on the app daily.

Window movement between Spaces, fullscreen overlays, persistent Groups, and guaranteed always-on-top foreign windows remain unsupported. Quick App All Desktops assignment can persist after stopping Atelier; undo it through Dock → Options → Assign To → None. Desktop creation uses macOS's window-management bridge without opening Mission Control and supports one display; reorder and delete still use Mission Control. All Space operations retain native animations. HS2 remains experimental; upgrades require explicit behavior verification.
