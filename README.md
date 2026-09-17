# Atelier

Atelier is a keyboard-driven workspace for macOS: Desktops, ordered window lists, Quick Apps, and a leader menu. It is one native Mac app and an `atelier` command.

This is a clean slate. The design is in [ATE-57](https://linear.app/elevenideas/issue/ATE-57/research-native-atelier-architecture-without-hammerspoon-2), and the code arrives ticket by ticket.

## The Hammerspoon version

Atelier previously ran on Hammerspoon 2. That version is kept in two tags, not in this tree:

- `hammerspoon-final`: the complete version. Its `api/`, `defaults/`, and `tests/` describe the behaviour the native app must match, and its README lists the manual trial.
- `hammerspoon-companion`: the above plus the `Atelier.app` Xcode project and the Spotlight action.

Read behaviour and pull individual files from those tags. Do not restore either tree wholesale; the shapes belong to the old design.

## Build and check

Atelier builds for Apple silicon Macs only. Install Xcode and mise, then run `mise install`. `mise tasks` lists the entry points and `mise run check` is the gate CI runs.

`mise run dev` builds and opens the development app, which appears in the menu bar. It needs the Accessibility permission; its popover says so and opens the right settings pane. The build is signed with your Apple Development certificate when you have one, so the permission survives rebuilds.

`mise run build` also builds the `atelier` command at `.build/debug/atelier`; `atelier --help` lists what it can ask the running app, one subcommand per request, such as `atelier desktops new` or `atelier windows move by -1`. The two talk over a socket in `~/Library/Application Support/Atelier/`, where the app also keeps the window lists between runs. Changing Desktops needs macOS 27.
