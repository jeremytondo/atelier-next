// Atelier defaults are optional. Edit this file, then choose Reload Config.
// You can also call hs APIs directly and require your own JavaScript modules.
const options = {
  spaces: true,
  groups: true,
  overlay: true,
  // bindings: {"desktop-create": "ctrl-option-n", "select-1": "none"},
  quickApps: [
    {app: "Calculator", shortcut: "cmd-shift-c"},
    // {app: "1Password", shortcut: "ctrl-option-p", size: {width: 900, height: 650}},
  ],
};
atelier.start(options).catch(console.error);

// Example customization, independent of Atelier's defaults:
// globalThis.myShortcut = hs.hotkey.bind(["cmd", "alt"], "t", () => {
//   hs.application.launchOrFocus("com.apple.Terminal").catch(console.error);
// }, null);
