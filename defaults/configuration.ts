// Configuration is ordinary HS2 JavaScript. Validate the defaults' options before
// registering anything, so an invalid edit cannot leave half the shortcuts active.
const modifiers: Record<string, string> = {
  cmd: "cmd",
  command: "cmd",
  option: "alt",
  opt: "alt",
  alt: "alt",
  ctrl: "ctrl",
  control: "ctrl",
  shift: "shift",
};
const keys: Record<string, string> = {
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
/** Quick Apps and presets each take at most this many entries. */
const listLimit = 50;

export interface Shortcut {
  mods: string[];
  key: string;
  identity: string;
}

export interface QuickAppSize {
  width: number;
  height: number;
}

export interface QuickAppOption {
  app: string;
  shortcut: string;
  size?: QuickAppSize;
}

export interface PresetOption {
  name: string;
  /** App names, bundle IDs, or absolute `.app` paths; position is the window number. */
  apps: string[];
  shortcut?: string;
}

/** Everything `atelier.start` accepts. */
export interface Options {
  spaces?: boolean;
  windows?: boolean;
  overlay?: boolean;
  overlayModifiers?: string;
  bindings?: Record<string, string>;
  quickApps?: QuickAppOption[];
  presets?: PresetOption[];
}

export interface Binding extends Shortcut {
  name: string;
  /** Desktop bindings are disabled while a Space operation runs. */
  space: boolean;
}

export interface QuickAppEntry extends Shortcut {
  app: string;
  shortcut: string;
  size?: QuickAppSize;
}

export interface PresetEntry {
  name: string;
  apps: string[];
  /** The parsed shortcut with the text it came from. */
  shortcut?: Shortcut & {text: string};
}

export interface Config {
  spaces: boolean;
  windows: boolean;
  overlay: boolean;
  overlayModifiers: string;
  overlayFlags: string[];
  bindings: Record<string, string>;
  shortcuts: Binding[];
  quickApps: QuickAppEntry[];
  presets: PresetEntry[];
}

export function shortcut(text: unknown): Shortcut {
  if (typeof text !== "string") throw new Error("A shortcut must be a string");
  const parts = text.toLowerCase().split("-"),
    mods: string[] = [];
  while (parts.length > 1) {
    const mod = modifiers[parts[0] ?? ""];
    if (!mod) break;
    mods.push(mod);
    parts.shift();
  }
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

export function defaultBindings(): Record<string, string> {
  const bindings: Record<string, string> = {
    "reload-config": "ctrl-option-cmd-r",
    presets: "cmd-option-p",
    "cycle-previous": "cmd-option-left-bracket",
    "cycle-next": "cmd-option-right-bracket",
    "move-previous": "cmd-option-shift-left-bracket",
    "move-next": "cmd-option-shift-right-bracket",
    "desktop-create": "option-grave",
    "desktop-left": "ctrl-option-left",
    "desktop-right": "ctrl-option-right",
    "desktop-delete": "ctrl-option-delete",
  };
  for (let n = 1; n <= 10; n++) {
    bindings["desktop-" + n] = "option-" + (n % 10);
    bindings["select-" + n] = "cmd-option-" + (n % 10);
    bindings["move-" + n] = "cmd-option-shift-" + (n % 10);
  }
  return bindings;
}

/** A fresh copy of the shipped defaults. */
export function defaults(): Required<Options> {
  return {
    spaces: true,
    windows: true,
    overlay: true,
    overlayModifiers: "cmd-option",
    bindings: defaultBindings(),
    quickApps: [{app: "Calculator", shortcut: "cmd-shift-c"}],
    presets: [],
  };
}

const isText = (value: unknown): value is string => typeof value === "string" && !!value.trim();

function checkKeys(candidate: object, allowed: string[], what: string) {
  for (const name of Object.keys(candidate)) {
    if (!allowed.includes(name)) throw new Error("Unknown " + what + " option: " + name);
  }
}

export function normalize(options: unknown = {}): Config {
  if (!options || typeof options !== "object" || Array.isArray(options))
    throw new Error("Options must be an object");
  const given = options as Record<string, unknown>;
  checkKeys(given, Object.keys(defaults()), "Atelier");
  const merged = {...defaults(), ...(given as Options)};
  for (const name of ["spaces", "windows", "overlay"] as const) {
    if (typeof merged[name] !== "boolean") throw new Error(name + " must be true or false");
  }
  const bindings = {...defaultBindings(), ...(merged.bindings as Record<string, string>)};
  for (const name of ["quickApps", "presets"] as const) {
    if (!Array.isArray(merged[name]) || merged[name].length > listLimit)
      throw new Error(name + " must be an array of at most " + listLimit + " entries");
  }
  const used = new Map<string, string>();
  const claim = (text: unknown, name: string) => {
    const parsed = shortcut(text);
    if (used.has(parsed.identity))
      throw new Error(name + " conflicts with " + used.get(parsed.identity));
    used.set(parsed.identity, name);
    return parsed;
  };
  const shortcuts: Binding[] = [];
  for (const [name, text] of Object.entries(bindings)) {
    if (!Object.hasOwn(defaultBindings(), name)) throw new Error("Unknown binding: " + name);
    const space = name.startsWith("desktop-");
    if (
      text === "none" ||
      (space && !merged.spaces) ||
      (!space && name !== "reload-config" && !merged.windows)
    )
      continue;
    shortcuts.push({name, space, ...claim(text, name)});
  }
  const quickApps = merged.quickApps.map((entry: unknown, index): QuickAppEntry => {
    const candidate = entry as Partial<QuickAppOption> | null;
    if (!candidate || !isText(candidate.app))
      throw new Error("Quick App " + (index + 1) + " needs an app");
    checkKeys(candidate, ["app", "shortcut", "size"], "Quick App");
    const size = candidate.size;
    if (
      size &&
      (Object.keys(size).some((k) => !["width", "height"].includes(k)) ||
        ![size.width, size.height].every((v) => Number.isFinite(v) && v > 0))
    )
      throw new Error("Invalid size for " + candidate.app);
    const app = candidate.app.trim();
    return {
      app,
      shortcut: String(candidate.shortcut),
      ...(size ? {size} : {}),
      ...claim(candidate.shortcut, app),
    };
  });
  const quickAppNames = new Set(quickApps.map((entry) => entry.app));
  const presetNames = new Set<string>();
  // Presets are validated even with `windows: false`, like the rest of the options.
  const presets = merged.presets.map((entry: unknown, index): PresetEntry => {
    const candidate = entry as Partial<PresetOption> | null;
    if (!candidate || !isText(candidate.name))
      throw new Error("Preset " + (index + 1) + " needs a name");
    const name = candidate.name.trim(),
      label = 'Preset "' + name + '"';
    checkKeys(candidate, ["name", "apps", "shortcut"], label);
    if (presetNames.has(name)) throw new Error(label + " is listed twice");
    presetNames.add(name);
    if (!Array.isArray(candidate.apps) || !candidate.apps.length || !candidate.apps.every(isText))
      throw new Error(label + " needs a list of app names");
    const apps = candidate.apps.map((app) => app.trim());
    for (const [position, app] of apps.entries()) {
      if (apps.indexOf(app) !== position) throw new Error(label + " lists " + app + " twice");
      if (quickAppNames.has(app)) throw new Error(label + " lists the Quick App " + app);
    }
    if (candidate.shortcut === undefined) return {name, apps};
    return {
      name,
      apps,
      shortcut: {text: String(candidate.shortcut), ...claim(candidate.shortcut, label)},
    };
  });
  return {
    spaces: merged.spaces,
    windows: merged.windows,
    overlay: merged.overlay,
    overlayModifiers: merged.overlayModifiers,
    overlayFlags: shortcut(merged.overlayModifiers + "-a").mods,
    bindings,
    shortcuts,
    quickApps,
    presets,
  };
}
