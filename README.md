# Atelier Next

Atelier is a keyboard-driven workspace for macOS: Desktops, ordered window lists, Quick Apps, and a leader menu.

This is the native rebuild: one Mac app and a command-line tool, with no Hammerspoon. The design and its reasons are in [ATE-57](https://linear.app/elevenideas/issue/ATE-57/research-native-atelier-architecture-without-hammerspoon-2). The last Hammerspoon 2 version is the `hammerspoon-final` tag; its `api/`, `defaults/`, `tests/`, and README manual trial describe the behaviour the native app must match.

## Layout

The target layout is in ATE-57. Until the first native tickets land, the tree holds the two Swift packages carried over from the Hammerspoon version. They are raw material, not the final shape:

- `providers/`: Desktop operations, the window inventory, and app launching. This becomes `Sources/MacOS`. Its pipe protocol and process host exist only to serve Hammerspoon and go away as the code is reworked.
- `companion/`: `companion/App` is the Xcode project for `Atelier.app` and becomes `App/`. The `Companion` library talks to Hammerspoon over HTTP and goes away.

## Build and check

Install Xcode and mise, then run `mise install`. `mise tasks` lists the entry points. `mise run check` is the gate CI runs, `mise run test` runs the Swift tests, and `mise run format` applies the formatter that `mise run lint` enforces.

Release and installation tooling returns with the native app's first release; the Hammerspoon version's tooling is at the `hammerspoon-final` tag.
