"use strict";
// Configuration is ordinary HS2 JavaScript. Validate the defaults' options before
// registering anything, so an invalid edit cannot leave half the shortcuts active.
const modifiers = {
  cmd: "cmd",
  command: "cmd",
  option: "alt",
  opt: "alt",
  alt: "alt",
  ctrl: "ctrl",
  control: "ctrl",
  shift: "shift",
};
const keys = {
  grave: "`",
  minus: "-",
  equal: "=",
  "left-bracket": "[",
  "right-bracket": "]",
  comma: ",",
  period: ".",
  slash: "/",
  semicolon: ";",
  quote: "'",
  backslash: "\\",
  enter: "return",
  esc: "escape",
};
function shortcut(text) {
  if (typeof text !== "string") throw new Error("A shortcut must be a string");
  const parts = text.toLowerCase().split("-"),
    mods = [];
  while (parts.length > 1 && modifiers[parts[0]]) mods.push(modifiers[parts.shift()]);
  const key = keys[parts.join("-")] || parts.join("-");
  if (
    !mods.length ||
    new Set(mods).size !== mods.length ||
    !/^([a-z0-9`\-=,./;'\\[\]]|space|return|tab|escape|delete|forwarddelete|left|right|up|down|home|end|pageup|pagedown|f([1-9]|1[0-9]|20))$/.test(
      key,
    )
  ) {
    throw new Error("Invalid shortcut: " + text);
  }
  return {mods, key, identity: [...mods].sort().join("+") + ":" + key};
}
function defaultBindings() {
  const bindings = {
    "reload-config": "ctrl-option-cmd-r",
    group: "cmd-option-g",
    "cycle-previous": "cmd-option-left-bracket",
    "cycle-next": "cmd-option-right-bracket",
    "desktop-create": "option-grave",
    "desktop-left": "ctrl-option-left",
    "desktop-right": "ctrl-option-right",
    "desktop-delete": "ctrl-option-delete",
  };
  for (let n = 1; n <= 10; n++) {
    bindings["desktop-" + n] = "option-" + (n % 10);
    bindings["select-" + n] = "cmd-option-" + (n % 10);
  }
  return bindings;
}
function defaults() {
  return {
    spaces: true,
    groups: true,
    overlay: true,
    overlayModifiers: "cmd-option",
    launchAtLogin: null,
    bindings: defaultBindings(),
    quickApps: [{app: "Calculator", shortcut: "cmd-shift-c"}],
  };
}
function normalize(options = {}) {
  if (!options || typeof options !== "object" || Array.isArray(options))
    throw new Error("Options must be an object");
  const config = {...defaults(), ...options, bindings: {...defaultBindings(), ...options.bindings}};
  for (const name of Object.keys(options)) {
    if (!Object.hasOwn(defaults(), name)) throw new Error("Unknown Atelier option: " + name);
  }
  for (const name of ["spaces", "groups", "overlay"]) {
    if (typeof config[name] !== "boolean") throw new Error(name + " must be true or false");
  }
  config.overlayFlags = shortcut(config.overlayModifiers + "-a").mods;
  if (config.launchAtLogin !== null && typeof config.launchAtLogin !== "boolean")
    throw new Error("launchAtLogin must be true, false, or null");
  if (!Array.isArray(config.quickApps) || config.quickApps.length > 50)
    throw new Error("quickApps must be an array of at most 50 entries");
  const used = new Map();
  const claim = (text, name) => {
    const parsed = shortcut(text);
    if (used.has(parsed.identity))
      throw new Error(name + " conflicts with " + used.get(parsed.identity));
    used.set(parsed.identity, name);
    return parsed;
  };
  config.shortcuts = [];
  for (const [name, text] of Object.entries(config.bindings)) {
    if (!Object.hasOwn(defaultBindings(), name)) throw new Error("Unknown binding: " + name);
    const space = name.startsWith("desktop-");
    if (
      text === "none" ||
      (space && !config.spaces) ||
      (!space && name !== "reload-config" && !config.groups)
    )
      continue;
    config.shortcuts.push({name, space, ...claim(text, name)});
  }
  config.quickApps = config.quickApps.map((entry, index) => {
    if (!entry || typeof entry.app !== "string" || !entry.app.trim())
      throw new Error("Quick App " + (index + 1) + " needs an app");
    for (const name of Object.keys(entry)) {
      if (["app", "shortcut", "size"].includes(name)) continue;
      throw new Error("Unknown Quick App option: " + name);
    }
    if (
      entry.size &&
      (Object.keys(entry.size).some((k) => !["width", "height"].includes(k)) ||
        ![entry.size.width, entry.size.height].every((v) => Number.isFinite(v) && v > 0))
    )
      throw new Error("Invalid size for " + entry.app);
    return {...entry, app: entry.app.trim(), ...claim(entry.shortcut, entry.app)};
  });
  return config;
}
module.exports = {defaults, normalize, shortcut};
