# Atelier Next

Prototypes and explorations for the next version of Atelier.

## Prototypes

- [Native macOS window tiling](Prototypes/NativeWindowTilingPOC/README.md) — ATE-13 prototype invoking native tiling through Accessibility menu commands. Try it on your own windows with `./tile-window left` after following the build instructions. The [evidence review and application research](Prototypes/NativeWindowTilingPOC/REVIEW.md) explains the approach and remaining limits; the [original findings](Prototypes/NativeWindowTilingPOC/FINDINGS.md) preserve earlier experiments.
- [Desktop Groups](Prototypes/NativeWindowTilingPOC/DESKTOP-GROUPS.md) — ATE-14 session-only grouped Desktop prototype with global indexed-focus shortcuts, automatic membership, and best-effort native Fill. Build the package, verify the read-only boundary with `./desktop-groups --probe`, then run `./desktop-groups`.
