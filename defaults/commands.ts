// The command registry: one identity per action with its label, availability,
// and every way to reach it. Global chords and leader sequences are resolved
// here, against the same commands, before anything is registered. A sequence
// is either a command or a submenu prefix; it cannot be both.
import {type NativeActionName, nativeActions} from "../api/window.ts";
import type {Chord} from "./keys.ts";
import {describe, describeSequence, sequenceIdentity} from "./keys.ts";

export interface Command {
  id: string;
  label: string;
  run(): Promise<unknown>;
  /** Why the command cannot run now, or null when it can. Never called from a key-event callback. */
  available?(): string | null;
  /** Whether the HUD lists the command now, so a Desktop that does not exist is
   *  left out rather than dimmed. Never called from a key-event callback. */
  listed?(): boolean;
  /** The macOS shortcut that reaches this command without Atelier, for the HUD. */
  native?(): Chord | null;
  /** Disabled while a Space operation runs. */
  space?: boolean;
}

export type Commands = Map<string, Command>;

/** A shipped command: its identity, label, and the feature that must be on for it to exist. */
export interface Builtin {
  id: string;
  label: string;
  feature?: "spaces" | "windows";
  space?: boolean;
  native?: NativeActionName;
}

const native = (id: string, name: NativeActionName): Builtin => ({
  id,
  label: nativeActions[name].label,
  native: name,
});

export const builtins: Builtin[] = [
  ...Array.from({length: 10}, (_, i) => ({
    id: "desktop-" + (i + 1),
    label: "Desktop " + (i + 1),
    feature: "spaces" as const,
    space: true,
  })),
  {id: "desktop-create", label: "Create Desktop", feature: "spaces", space: true},
  {id: "desktop-delete", label: "Delete Desktop", feature: "spaces", space: true},
  {id: "desktop-left", label: "Move Desktop Left", feature: "spaces", space: true},
  {id: "desktop-right", label: "Move Desktop Right", feature: "spaces", space: true},
  ...Array.from({length: 10}, (_, i) => ({
    id: "select-" + (i + 1),
    label: "Window " + (i + 1),
    feature: "windows" as const,
  })),
  {id: "cycle-previous", label: "Previous Window", feature: "windows"},
  {id: "cycle-next", label: "Next Window", feature: "windows"},
  ...Array.from({length: 10}, (_, i) => ({
    id: "move-" + (i + 1),
    label: "Move to " + (i + 1),
    feature: "windows" as const,
  })),
  {id: "move-previous", label: "Move Earlier", feature: "windows"},
  {id: "move-next", label: "Move Later", feature: "windows"},
  {id: "presets", label: "Presets"},
  native("window-fill", "fill"),
  native("window-center", "center"),
  native("window-left", "left"),
  native("window-right", "right"),
  native("window-top", "top"),
  native("window-bottom", "bottom"),
  native("window-top-left", "top-left"),
  native("window-top-right", "top-right"),
  native("window-bottom-left", "bottom-left"),
  native("window-bottom-right", "bottom-right"),
  native("arrange-left-right", "left-right"),
  native("arrange-right-left", "right-left"),
  native("arrange-top-bottom", "top-bottom"),
  native("arrange-bottom-top", "bottom-top"),
  native("arrange-left-quarters", "left-quarters"),
  native("arrange-right-quarters", "right-quarters"),
  native("arrange-top-quarters", "top-quarters"),
  native("arrange-bottom-quarters", "bottom-quarters"),
  native("arrange-quarters", "quarters"),
  {id: "open-config", label: "Open Configuration"},
  {id: "reload-config", label: "Reload Configuration"},
  {id: "console", label: "Hammerspoon Console"},
];

/** Quick Apps and presets are commands too, named after their configuration. */
export const quickAppCommand = (app: string): string => "quick-app:" + app;
export const presetCommand = (name: string): string => "preset:" + name;

/** What a global chord does: its command, or nothing at all for a disabled chord. */
export interface GlobalBinding {
  chord: Chord;
  command: Command | null;
}

export interface Menu {
  label: string;
  entries: MenuEntry[];
}

export type MenuEntry =
  | {chord: Chord; menu: Menu; command?: undefined}
  | {chord: Chord; command: Command; menu?: undefined};

export interface Keymap {
  global: GlobalBinding[];
  leader: Menu;
}

/** One configured global chord after merging the defaults with the user's map. */
export interface GlobalMapping {
  text: string;
  chord: Chord;
  /** A command identity, or false for a disabled chord. */
  target: string | false;
  user: boolean;
}

/** One configured leader sequence after merging. */
export interface LeaderMapping {
  text: string;
  chords: Chord[];
  /** A command identity, false to disable the sequence, or a submenu label. */
  target: string | false | {menu: string};
  user: boolean;
}

interface Node {
  label: string;
  chord: Chord;
  command?: Command;
  children: Map<string, Node>;
}

function reference(target: string, commands: Commands, user: boolean, text: string) {
  const command = commands.get(target);
  if (!command && user) throw new Error("Unknown command for " + text + ": " + target);
  return command;
}

export function resolveKeymap(
  globals: Iterable<GlobalMapping>,
  leader: Iterable<LeaderMapping>,
  commands: Commands,
): Keymap {
  const global: GlobalBinding[] = [];
  for (const mapping of globals) {
    if (mapping.target === false) {
      if (mapping.user) global.push({chord: mapping.chord, command: null});
      continue;
    }
    const command = reference(mapping.target, commands, mapping.user, mapping.text);
    if (command) global.push({chord: mapping.chord, command});
  }
  // A user's disabled sequence, or a user command at a shipped prefix, replaces
  // everything shipped under it; the user's own longer sequences must not pass
  // through a command.
  const mappings = [...leader],
    disabled = mappings.filter((m) => m.user && m.target === false).map((m) => m.chords),
    replaced = mappings.filter((m) => m.user && typeof m.target === "string").map((m) => m.chords);
  const under = (chords: Chord[], prefix: Chord[]) =>
    chords.length > prefix.length &&
    sequenceIdentity(chords.slice(0, prefix.length)) === sequenceIdentity(prefix);
  const root: Node = {
    label: "Atelier",
    chord: {mods: [], key: "", identity: ""},
    children: new Map(),
  };
  for (const mapping of mappings) {
    if (mapping.target === false) continue;
    const blocked = disabled.find(
      (prefix) =>
        under(mapping.chords, prefix) ||
        sequenceIdentity(mapping.chords) === sequenceIdentity(prefix),
    );
    if (blocked) {
      if (mapping.user)
        throw new Error(
          mapping.text + " is under the disabled sequence " + describeSequence(blocked),
        );
      continue;
    }
    if (!mapping.user && replaced.some((prefix) => under(mapping.chords, prefix))) continue;
    let node = root;
    for (const [index, chord] of mapping.chords.entries()) {
      const last = index === mapping.chords.length - 1,
        text = mapping.chords
          .slice(0, index + 1)
          .map(describe)
          .join(" ");
      let child = node.children.get(chord.identity);
      if (!child) {
        child = {label: describe(chord), chord, children: new Map()};
        node.children.set(chord.identity, child);
      }
      if (!last) {
        if (child.command)
          throw new Error(text + " is both a command and a prefix of " + mapping.text);
      } else if (typeof mapping.target === "string") {
        if (child.children.size)
          throw new Error(mapping.text + " is both a command and a prefix of another sequence");
        const command = reference(mapping.target, commands, mapping.user, mapping.text);
        if (!command) node.children.delete(chord.identity);
        else child.command = command;
      } else {
        if (child.command) throw new Error(mapping.text + " is both a submenu and a command");
        child.label = mapping.target.menu;
      }
      node = child;
    }
  }
  const build = (node: Node): Menu => ({
    label: node.label,
    entries: [...node.children.values()].flatMap((child): MenuEntry[] => {
      if (child.command) return [{chord: child.chord, command: child.command}];
      const menu = build(child);
      // A prefix with nothing configured under it is not shown and not a key.
      return menu.entries.length ? [{chord: child.chord, menu}] : [];
    }),
  });
  return {global, leader: build(root)};
}

/** The global chords that reach a command, for the HUD and the Console. */
export function shortcutsFor(keymap: Keymap, command: Command): Chord[] {
  return keymap.global.filter((b) => b.command === command).map((b) => b.chord);
}
