// The key grammar shared by every mapping: a chord is optional modifiers and
// one key, a sequence is chords separated by spaces. Identities are the
// normalized form, so `command-alt-1` and `cmd-option-1` are one chord.
// Modifier symbols follow the macOS menu convention for the HUD.
const modifierNames: Record<string, string> = {
  cmd: "cmd",
  command: "cmd",
  option: "alt",
  opt: "alt",
  alt: "alt",
  ctrl: "ctrl",
  control: "ctrl",
  shift: "shift",
  fn: "fn",
};
const keyNames: Record<string, string> = {
  grave: "`",
  minus: "-",
  equal: "=",
  "left-bracket": "[",
  leftbracket: "[",
  "right-bracket": "]",
  rightbracket: "]",
  comma: ",",
  period: ".",
  slash: "/",
  semicolon: ";",
  quote: "'",
  backslash: "\\",
  enter: "return",
  esc: "escape",
  backspace: "delete",
};
const keyPattern =
  /^([a-z0-9`\-=,./;'\\[\]]|space|return|tab|escape|delete|forwarddelete|left|right|up|down|home|end|pageup|pagedown|f([1-9]|1[0-9]|20))$/;
/** Modifier order in identities and on screen: the order macOS menus use. */
const modifierOrder = ["fn", "ctrl", "alt", "shift", "cmd"];
const modifierSymbols: Record<string, string> = {
  fn: "fn",
  ctrl: "⌃",
  alt: "⌥",
  shift: "⇧",
  cmd: "⌘",
};
const keySymbols: Record<string, string> = {
  left: "←",
  right: "→",
  up: "↑",
  down: "↓",
  space: "Space",
  return: "↩",
  tab: "⇥",
  escape: "Esc",
  delete: "⌫",
  forwarddelete: "⌦",
  home: "↖",
  end: "↘",
  pageup: "⇞",
  pagedown: "⇟",
};

export interface Chord {
  /** HS2 modifier names in the order `modifierOrder` lists them. */
  mods: string[];
  key: string;
  /** `mods` joined by `+`, then `:` and the key; equal for equal chords. */
  identity: string;
}

/** Parses `cmd-option-1`; every chord needs a modifier unless `bare` allows a lone key. */
export function chord(text: unknown, bare = false): Chord {
  if (typeof text !== "string") throw new Error("A shortcut must be a string");
  const parts = text.trim().toLowerCase().split("-"),
    mods = new Set<string>();
  while (parts.length > 1) {
    const mod = modifierNames[parts[0] ?? ""];
    if (!mod) break;
    if (mods.has(mod)) throw new Error("Invalid shortcut: " + text);
    mods.add(mod);
    parts.shift();
  }
  const key = keyNames[parts.join("-")] || parts.join("-");
  if ((!mods.size && !bare) || !keyPattern.test(key)) throw new Error("Invalid shortcut: " + text);
  return make([...mods], key);
}

/** The chord for a key event: HS2's modifier flags and the layout's name for the key code. */
export function eventChord(flags: string[], key: string): Chord {
  const mods = flags.filter((flag) => modifierOrder.includes(flag));
  return make(mods, keyNames[key] || key);
}

function make(mods: string[], key: string): Chord {
  const ordered = modifierOrder.filter((mod) => mods.includes(mod));
  return {mods: ordered, key, identity: ordered.join("+") + ":" + key};
}

/** Parses `w shift-left` into chords; leader keys need no modifier. Fn is not
 *  a leader modifier: macOS sets it on arrow keys by itself. */
export function sequence(text: unknown): Chord[] {
  if (typeof text !== "string" || !text.trim()) throw new Error("A sequence must be a string");
  return text
    .trim()
    .split(/\s+/)
    .map((token) => {
      const parsed = chord(token, true);
      if (parsed.mods.includes("fn")) throw new Error("Fn cannot be part of a sequence: " + text);
      return parsed;
    });
}

export const sequenceIdentity = (chords: Chord[]): string =>
  chords.map((c) => c.identity).join(" ");

/** `⌥⌘1`, `⇧←`, `fn⌃F`: how macOS menus print a shortcut. */
export function describe(value: Chord): string {
  const key =
    keySymbols[value.key] ?? (value.key.length === 1 ? value.key.toUpperCase() : value.key);
  return value.mods.map((mod) => modifierSymbols[mod] ?? mod).join("") + key;
}

export const describeSequence = (chords: Chord[]): string => chords.map(describe).join(" ");
