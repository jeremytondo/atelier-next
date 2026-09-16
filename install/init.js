// Your Atelier configuration. Hammerspoon 2 loads this file at start and on
// Reload Config. Updates preserve it; atelier repair backs it up before restoring defaults.
const atelier = require("/opt/homebrew/share/atelier");

atelier
  .start({
    spaces: true,
    windows: true,
    overlay: true,
    // leader: "option-space", // press and release, then type a sequence such as `w f`
    // hud: {delay: 0, timeout: 10},
    quickApps: [
      {app: "Calculator", shortcut: "cmd-shift-c"},
      // {app: "1Password", shortcut: "ctrl-option-p", size: {width: 900, height: 650}},
    ],
    // Apply a preset to an empty Desktop with its shortcut or the Cmd-Option-P picker:
    // presets: [{name: "Dev", shortcut: "cmd-option-d", apps: ["Ghostty", "Safari"]}],
    // keymap: {
    //   global: {"ctrl-option-n": "desktop-create", "cmd-option-1": false},
    //   leader: {"a c": "quick-app:Calculator", "s p d": "preset:Dev"},
    // },
    // commands: {
    //   terminal: {label: "Terminal", action: () => hs.application.launchOrFocus("com.apple.Terminal")},
    // },
  })
  .catch(console.error);

// Your own automations run beside the defaults with the full hs API. Keep a
// reference to anything with a callback so it is not garbage collected:
// globalThis.terminal = hs.hotkey.bind(["cmd", "alt"], "t", () => {
//   hs.application.launchOrFocus("com.apple.Terminal").catch(console.error);
// }, null);
