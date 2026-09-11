# Atelier Next

Prototypes and explorations for the next version of Atelier.

## Prototypes

- [Native macOS window tiling](Prototypes/NativeWindowTilingPOC/README.md) — ATE-13 prototype invoking native tiling through Accessibility menu commands. Try it on your own windows with `./tile-window left` after following the build instructions. The [evidence review and application research](Prototypes/NativeWindowTilingPOC/REVIEW.md) explains the approach and remaining limits; the [original findings](Prototypes/NativeWindowTilingPOC/FINDINGS.md) preserve earlier experiments.
- [Desktop Groups](Prototypes/NativeWindowTilingPOC/DESKTOP-GROUPS.md) — ATE-14 session-only grouped Desktop prototype with global indexed-focus shortcuts, automatic membership, and best-effort native Fill. Build the package, verify the read-only boundary with `./desktop-groups --probe`, then run `./desktop-groups`.
- [Space Control](Prototypes/NativeWindowTilingPOC/SPACE-CONTROL.md) — ATE-15 session-only `Option-1…0` Desktop switching plus native create-and-switch on ``Option-` ``. Build the package, inspect the read-only topology with `./space-control --probe`, then run `./space-control`.
- [Scratchpad](Prototypes/NativeWindowTilingPOC/SCRATCHPAD.md) — ATE-16 app summon/hide prototype with automatic verified All Desktops assignment, a configurable global shortcut, native placement, and focus restoration. Build the package, validate configuration with `./scratchpad --app Calculator --probe`, then run it directly.
