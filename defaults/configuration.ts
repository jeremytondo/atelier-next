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

/** Everything `atelier.start` accepts. */
export interface Options {
  spaces?: boolean;
  groups?: boolean;
  overlay?: boolean;
  overlayModifiers?: string;
  bindings?: Record<string, string>;
  quickApps?: QuickAppOption[];
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

export interface Config {
  spaces: boolean;
  groups: boolean;
  overlay: boolean;
  overlayModifiers: string;
  overlayFlags: string[];
  bindings: Record<string, string>;
  shortcuts: Binding[];
  quickApps: QuickAppEntry[];
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

/** A fresh copy of the shipped defaults. */
export function defaults(): Required<Options> {
  return {
    spaces: true,
    groups: true,
    overlay: true,
    overlayModifiers: "cmd-option",
    bindings: defaultBindings(),
    quickApps: [{app: "Calculator", shortcut: "cmd-shift-c"}],
  };
}

export function normalize(options: unknown = {}): Config {
  if (!options || typeof options !== "object" || Array.isArray(options))
    throw new Error("Options must be an object");
  const given = options as Record<string, unknown>;
  for (const name of Object.keys(given)) {
    if (!Object.hasOwn(defaults(), name)) throw new Error("Unknown Atelier option: " + name);
  }
  const merged = {...defaults(), ...(given as Options)};
  for (const name of ["spaces", "groups", "overlay"] as const) {
    if (typeof merged[name] !== "boolean") throw new Error(name + " must be true or false");
  }
  const bindings = {...defaultBindings(), ...(merged.bindings as Record<string, string>)};
  if (!Array.isArray(merged.quickApps) || merged.quickApps.length > 50)
    throw new Error("quickApps must be an array of at most 50 entries");
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
      (!space && name !== "reload-config" && !merged.groups)
    )
      continue;
    shortcuts.push({name, space, ...claim(text, name)});
  }
  const quickApps = merged.quickApps.map((entry: unknown, index): QuickAppEntry => {
    const candidate = entry as Partial<QuickAppOption> | null;
    if (!candidate || typeof candidate.app !== "string" || !candidate.app.trim())
      throw new Error("Quick App " + (index + 1) + " needs an app");
    for (const name of Object.keys(candidate)) {
      if (["app", "shortcut", "size"].includes(name)) continue;
      throw new Error("Unknown Quick App option: " + name);
    }
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
  return {
    spaces: merged.spaces,
    groups: merged.groups,
    overlay: merged.overlay,
    overlayModifiers: merged.overlayModifiers,
    overlayFlags: shortcut(merged.overlayModifiers + "-a").mods,
    bindings,
    shortcuts,
    quickApps,
  };
}
