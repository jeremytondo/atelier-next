// Configuration is ordinary HS2 JavaScript. Everything is validated here,
// before anything is registered, so an invalid edit cannot leave half the
// keymap active. Mappings are key-first: a chord or sequence names a command,
// and a user entry at the same key replaces the shipped one. `false` is the
// one way to disable a key.
import {
  builtins,
  type GlobalMapping,
  type LeaderMapping,
  presetCommand,
  quickAppCommand,
} from "./commands.ts";
import {type Chord, chord, sequence, sequenceIdentity} from "./keys.ts";

/** Quick Apps and presets each take at most this many entries. */
const listLimit = 50;

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

/** A user command: a label for the HUD and the function a key runs. */
export interface CommandOption {
  label: string;
  action: () => unknown;
  /** Returns why the command cannot run now, or nothing when it can. */
  available?: () => unknown;
}

export type LeaderTarget = string | false | {menu: string};

export interface KeymapOptions {
  /** Chord to command identity; false disables the chord while Atelier runs. */
  global?: Record<string, string | false>;
  /** Sequence to command identity, false, or `{menu}` to name a submenu. */
  leader?: Record<string, LeaderTarget>;
}

export interface HudOptions {
  /** Seconds before the leader HUD appears. */
  delay?: number;
  /** Seconds of leader inactivity before it ends; false never ends it. */
  timeout?: number | false;
}

/** Everything `atelier.start` accepts. */
export interface Options {
  spaces?: boolean;
  windows?: boolean;
  overlay?: boolean;
  overlayModifiers?: string;
  /** The chord that starts leader mode, or false for none. */
  leader?: string | false;
  hud?: HudOptions;
  commands?: Record<string, CommandOption>;
  keymap?: KeymapOptions;
  quickApps?: QuickAppOption[];
  presets?: PresetOption[];
}

export interface QuickAppEntry {
  app: string;
  shortcut: string;
  size?: QuickAppSize;
}

export interface PresetEntry {
  name: string;
  apps: string[];
  shortcut?: string;
}

export interface UserCommand extends CommandOption {
  id: string;
}

export interface Config {
  spaces: boolean;
  windows: boolean;
  overlay: boolean;
  overlayModifiers: string;
  overlayFlags: string[];
  leader: Chord | null;
  hud: {delay: number; timeout: number | null};
  commands: UserCommand[];
  global: GlobalMapping[];
  leaderMap: LeaderMapping[];
  quickApps: QuickAppEntry[];
  presets: PresetEntry[];
}

export function defaultGlobal(): Record<string, string> {
  const map: Record<string, string> = {
    "ctrl-option-cmd-r": "reload-config",
    "cmd-option-p": "presets",
    "cmd-option-left-bracket": "cycle-previous",
    "cmd-option-right-bracket": "cycle-next",
    "cmd-option-shift-left-bracket": "move-previous",
    "cmd-option-shift-right-bracket": "move-next",
    "option-grave": "desktop-create",
    "ctrl-option-left": "desktop-left",
    "ctrl-option-right": "desktop-right",
    "ctrl-option-delete": "desktop-delete",
  };
  for (let n = 1; n <= 10; n++) {
    map["option-" + (n % 10)] = "desktop-" + n;
    map["cmd-option-" + (n % 10)] = "select-" + n;
    map["cmd-option-shift-" + (n % 10)] = "move-" + n;
  }
  return map;
}

export function defaultLeader(): Record<string, LeaderTarget> {
  const map: Record<string, LeaderTarget> = {
    s: {menu: "Spaces"},
    "s n": "desktop-create",
    "s d": "desktop-delete",
    "s shift-left": "desktop-left",
    "s shift-right": "desktop-right",
    "s p": {menu: "Desktop Presets"},
    w: {menu: "Windows"},
    "w f": "window-fill",
    "w c": "window-center",
    "w left": "window-left",
    "w right": "window-right",
    "w up": "window-top",
    "w down": "window-bottom",
    "w t": {menu: "Top"},
    "w t l": "window-top-left",
    "w t r": "window-top-right",
    "w b": {menu: "Bottom"},
    "w b l": "window-bottom-left",
    "w b r": "window-bottom-right",
    "w a": {menu: "Arrange"},
    "w a left": "arrange-left-right",
    "w a right": "arrange-right-left",
    "w a up": "arrange-top-bottom",
    "w a down": "arrange-bottom-top",
    "w a shift-left": "arrange-left-quarters",
    "w a shift-right": "arrange-right-quarters",
    "w a shift-up": "arrange-top-quarters",
    "w a shift-down": "arrange-bottom-quarters",
    "w a q": "arrange-quarters",
    a: {menu: "Quick Apps"},
    c: {menu: "Configuration"},
    "c o": "open-config",
    "c r": "reload-config",
    "c c": "console",
  };
  for (let n = 1; n <= 10; n++) map["s " + (n % 10)] = "desktop-" + n;
  return map;
}

/** A fresh copy of the shipped defaults. */
export function defaults(): Required<Options> {
  return {
    spaces: true,
    windows: true,
    overlay: true,
    overlayModifiers: "cmd-option",
    leader: "option-space",
    hud: {delay: 0, timeout: 10},
    commands: {},
    keymap: {global: defaultGlobal(), leader: defaultLeader()},
    quickApps: [{app: "Calculator", shortcut: "cmd-shift-c"}],
    presets: [],
  };
}

const isText = (value: unknown): value is string => typeof value === "string" && !!value.trim();
const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);
const builtinIds = new Set(builtins.map((b) => b.id));

function checkKeys(candidate: object, allowed: string[], what: string) {
  for (const name of Object.keys(candidate)) {
    if (!allowed.includes(name)) throw new Error("Unknown " + what + " option: " + name);
  }
}

function seconds(value: unknown, name: string, minimum: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum)
    throw new Error("hud." + name + " must be a number of seconds, at least " + minimum);
  return value;
}

export function normalize(options: unknown = {}): Config {
  if (!isRecord(options)) throw new Error("Options must be an object");
  checkKeys(options, Object.keys(defaults()), "Atelier");
  const merged = {...defaults(), ...(options as Options)};
  for (const name of ["spaces", "windows", "overlay"] as const) {
    if (typeof merged[name] !== "boolean") throw new Error(name + " must be true or false");
  }
  const leader = merged.leader === false ? null : chord(merged.leader);
  if (!isRecord(merged.hud)) throw new Error("hud must be an object");
  checkKeys(merged.hud, ["delay", "timeout"], "hud");
  const hud = {
    delay: seconds(merged.hud.delay ?? 0, "delay", 0),
    timeout:
      merged.hud.timeout === false ? null : seconds(merged.hud.timeout ?? 10, "timeout", 0.1),
  };
  if (!isRecord(merged.commands)) throw new Error("commands must be an object");
  const commands = Object.entries(merged.commands).map(([id, entry]): UserCommand => {
    if (!isText(id) || /\s/.test(id))
      throw new Error("Invalid command identity: " + JSON.stringify(id));
    if (builtinIds.has(id) || /^(quick-app|preset):/.test(id))
      throw new Error("Command identity is reserved: " + id);
    if (!isRecord(entry)) throw new Error("Command " + id + " must be an object");
    checkKeys(entry, ["label", "action", "available"], "command " + id);
    if (!isText(entry.label)) throw new Error("Command " + id + " needs a label");
    if (typeof entry.action !== "function")
      throw new Error("Command " + id + " needs an action function");
    if (entry.available !== undefined && typeof entry.available !== "function")
      throw new Error("Command " + id + " has a non-function available");
    return {
      id,
      label: entry.label.trim(),
      action: entry.action as () => unknown,
      ...(entry.available ? {available: entry.available as () => unknown} : {}),
    };
  });
  // The shipped keymap is merged below, so only the user's own entries are read here.
  const keymap = (options as Options).keymap ?? {};
  if (!isRecord(keymap)) throw new Error("keymap must be an object");
  checkKeys(keymap, ["global", "leader"], "keymap");
  const userGlobal = keymap.global ?? {},
    userLeader = keymap.leader ?? {};
  if (!isRecord(userGlobal)) throw new Error("keymap.global must be an object");
  if (!isRecord(userLeader)) throw new Error("keymap.leader must be an object");

  // Global chords: the defaults, then user entries, Quick Apps, and presets,
  // each replacing a default at the same chord and refusing another user entry.
  const global = new Map<string, GlobalMapping>();
  for (const [text, target] of Object.entries(defaultGlobal())) {
    const parsed = chord(text);
    global.set(parsed.identity, {text, chord: parsed, target, user: false});
  }
  const users = new Map<string, string>();
  if (leader) users.set(leader.identity, "leader");
  const claim = (text: unknown, target: string | false, owner: string) => {
    const parsed = chord(text);
    const previous = users.get(parsed.identity);
    if (previous) throw new Error(owner + " conflicts with " + previous);
    users.set(parsed.identity, owner);
    global.set(parsed.identity, {text: String(text), chord: parsed, target, user: true});
  };
  for (const [text, target] of Object.entries(userGlobal)) {
    if (target !== false && !isText(target))
      throw new Error("keymap.global " + text + " must name a command or be false");
    claim(text, target, text);
  }
  // The leader is a user mapping of its chord: it replaces a shipped chord there.
  if (leader) global.delete(leader.identity);
  for (const name of ["quickApps", "presets"] as const) {
    if (!Array.isArray(merged[name]) || merged[name].length > listLimit)
      throw new Error(name + " must be an array of at most " + listLimit + " entries");
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
    claim(candidate.shortcut, quickAppCommand(app), app);
    return {app, shortcut: String(candidate.shortcut), ...(size ? {size} : {})};
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
    claim(candidate.shortcut, presetCommand(name), label);
    return {name, apps, shortcut: String(candidate.shortcut)};
  });

  // Leader sequences: the defaults, then user entries replacing them.
  const leaderMap = new Map<string, LeaderMapping>();
  for (const [text, target] of Object.entries(defaultLeader())) {
    const chords = sequence(text);
    leaderMap.set(sequenceIdentity(chords), {text, chords, target, user: false});
  }
  const userSequences = new Map<string, string>();
  for (const [text, target] of Object.entries(userLeader)) {
    const chords = sequence(text),
      identity = sequenceIdentity(chords);
    if (target !== false && !isText(target) && !(isRecord(target) && isText(target.menu)))
      throw new Error("keymap.leader " + text + " must name a command, a {menu}, or be false");
    if (isRecord(target)) checkKeys(target, ["menu"], "keymap.leader " + text);
    const previous = userSequences.get(identity);
    if (previous) throw new Error("keymap.leader " + text + " repeats " + previous);
    userSequences.set(identity, text);
    leaderMap.set(identity, {
      text,
      chords,
      target: isRecord(target) ? {menu: String(target.menu).trim()} : (target as string | false),
      user: true,
    });
  }
  return {
    spaces: merged.spaces,
    windows: merged.windows,
    overlay: merged.overlay,
    overlayModifiers: merged.overlayModifiers,
    overlayFlags: chord(merged.overlayModifiers + "-a").mods,
    leader,
    hud,
    commands,
    global: [...global.values()],
    leaderMap: [...leaderMap.values()],
    quickApps,
    presets,
  };
}
