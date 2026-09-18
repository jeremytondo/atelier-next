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

## Keys

The built-in shortcuts are the ones `atelier config show` lists. Option+Space opens the leader menu in the bottom-right corner of the screen: type a sequence such as `w f` for Fill or `s 3` for Desktop 3, Backspace goes up a level, Escape leaves, and a click or a switch of apps leaves too and lands where it was aimed. Every other key is consumed while the menu is open, so a typo never reaches the app. Holding Cmd+Option shows the current Desktop's numbered windows in the same corner, with Shift allowed for the reorder shortcuts.

## Configuration

Atelier runs with built-in keys and no Quick Apps. `~/.config/atelier/config-next.toml` overrides them (the name is temporary, while `config.toml` may still hold a file in an earlier draft format): `atelier config show` prints what is in effect, `atelier config open` opens the file (writing a commented starting point if there is none), and `atelier config reload`, the menu bar, or ⌃⌥⌘R applies your edits; nothing applies on save. A key is modifiers and a key joined by `+`, a value is a command as the terminal takes it, and `unbind` removes a key. `[leader]` sets the leader key, the delay before its menu appears, and the inactivity timeout (or `false`); `[window-list]` sets the modifiers that show the window list. A setting with a problem is left out and listed by `config show` and the menu bar until it is fixed; a file that cannot be parsed is refused whole, and the previous configuration stays in effect. To try a configuration without touching your own, start the app with `ATELIER_CONFIG=/path/to/config.toml` in its environment.

```toml
[keymap.global]
"ctrl+option+w" = "windows select 1"
"cmd+option+1" = "unbind"

[keymap.leader]
"x" = { menu = "Extras" }
"x n" = "desktops new"

[[quick-apps]]
app = "1Password"
leader = "a p"
shortcut = "ctrl+option+p"
```
