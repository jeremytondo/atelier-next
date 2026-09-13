# Atelier Next

Prototypes and explorations for the next version of Atelier.

## Application

[Atelier for macOS](App/README.md) is the standalone macOS app, with native Spaces, Groups, and configurable Quick Apps. Build and install with `mise run dev`; see the app README for permissions and updates, and [releasing](docs/releases.md) for rolling dev builds and stable semantic releases.

## Reference source

`mise run refs` creates a shallow checkout of [Hammerspoon 2](https://github.com/cmsj/Hammerspoon2) under `repos/hammerspoon2`. This directory is gitignored and used only for research. `mise run refs:update` fast-forwards it to upstream `main`, refusing local edits or commits; `mise run refs:status` shows the current revision and checkout state. Existing checkouts are left unchanged by `mise run refs`.

## Prototypes

- [Hammerspoon 2 Spaces, Groups, and Quick Apps](Prototypes/Hammerspoon2/README.md) — ATE-35 HS2 runtime with native Space operations, Fill-on-focus Groups, and configurable centered app toggles. Window movement between Spaces is currently disabled.
- [Native macOS window tiling](Prototypes/NativeWindowTilingPOC/README.md) — ATE-13 prototype invoking native tiling through Accessibility menu commands. Try it on your own windows with `./tile-window left` after following the build instructions. The [evidence review and application research](Prototypes/NativeWindowTilingPOC/REVIEW.md) explains the approach and remaining limits; the [original findings](Prototypes/NativeWindowTilingPOC/FINDINGS.md) preserve earlier experiments.
- [Desktop Groups](Prototypes/NativeWindowTilingPOC/DESKTOP-GROUPS.md) — ATE-14 session-only grouped Desktop prototype with global indexed-focus shortcuts, automatic membership, and best-effort native Fill. Build the package, verify the read-only boundary with `./desktop-groups --probe`, then run `./desktop-groups`.
- [Space Control](Prototypes/NativeWindowTilingPOC/SPACE-CONTROL.md) — ATE-15 session-only `Option-1…0` Desktop switching plus native create-and-switch on ``Option-` ``. Build the package, inspect the read-only topology with `./space-control --probe`, then run `./space-control`.
- [Scratchpad](Prototypes/NativeWindowTilingPOC/SCRATCHPAD.md) — ATE-16 app summon/hide prototype with automatic verified All Desktops assignment, a configurable global shortcut, native placement, and focus restoration. Build the package, validate configuration with `./scratchpad --app Calculator --probe`, then run it directly.
