// Your Atelier configuration. Hammerspoon 2 loads this file at start and on
// Reload Config. Updates preserve it; atelier repair backs it up before restoring defaults.
const atelier = require("/opt/homebrew/share/atelier");

atelier
  .start({
    spaces: true,
    groups: true,
    overlay: true,
    // bindings: {"desktop-create": "ctrl-option-n", "select-1": "none"},
    quickApps: [
      {app: "Calculator", shortcut: "cmd-shift-c"},
      // {app: "1Password", shortcut: "ctrl-option-p", size: {width: 900, height: 650}},
    ],
  })
  .catch(console.error);

// Your own automations run beside the defaults with the full hs API. Keep a
// reference to anything with a callback so it is not garbage collected:
// globalThis.terminal = hs.hotkey.bind(["cmd", "alt"], "t", () => {
//   hs.application.launchOrFocus("com.apple.Terminal").catch(console.error);
// }, null);
