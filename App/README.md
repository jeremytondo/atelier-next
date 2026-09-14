# Atelier

Atelier is a customizable macOS workspace for Apple silicon Macs running macOS 27. One menu-bar app owns the native interface and runs Hammerspoon 2's JavaScript engine, APIs, and Console in process. Its bundled native helper supplies Space and Quick App capabilities in a separate process. Installed use requires no separate Hammerspoon, Node, Xcode, or repository checkout.

## Install and use

Download the [dev ZIP](https://github.com/jeremytondo/atelier-next/releases/download/dev/Atelier-macos-arm64.zip), unzip it, quit the previous Atelier, and move `Atelier.app` into `/Applications`. The bundled [configuration reference](Resources/Configuration.md), also opened by the menu's **Configuration Reference** item, covers first launch and Accessibility, the configuration file and `atelier.start` options, default shortcuts, Groups, Quick Apps, recovery, and diagnostics.

The menu provides status and errors, Open Configuration, Configuration Reference, Reload Config, Pause/Resume Atelier Defaults, Console, Export Diagnostics, permissions help, releases, and Quit. Native windows focus normally; closing them leaves Atelier running without a persistent Dock icon.

## Build and check

Use the repository's mise tasks (`mise tasks`) and `scripts/build-app.sh --help`; see [releases](../docs/releases.md). `mise run dev` builds, installs, and launches a locally signed app. `mise run check` is the gate CI runs, and `mise run format` applies the Swift and JavaScript formatters that `mise run lint` enforces. AppleScript/XPC verification requires Apple signing and runs in signed packaging.

[The HS2 integration guide](Hammerspoon/README.md) explains the exact dependency pin, source reconstruction, compatibility shims, and upgrade gate. `repos/` is independent research material and never a build input. Runtime policy lives in `Resources/Atelier/`; native shell source lives in `Hammerspoon/Shell/` and `Hammerspoon/ShellCore/`; native helpers live in `Sources/`.

## Manual trial

Use disposable Desktops and saved windows for Desktop switching/create/reorder/delete, Groups, exact window selection and native Fill, the held-modifier overlay, and Quick Apps. Verify custom scripts, repeated reloads, and Pause/Resume. Permission and coexistence checks require a disposable environment. Check sleep/wake and multiple displays before relying on the app daily.

Desktop creation uses macOS's window-management bridge without opening Mission Control and supports one display; reorder and delete still use Mission Control. All Space operations retain native animations. HS2 remains experimental; upgrades require explicit behavior verification. The configuration reference lists the window behaviors Atelier does not support.
