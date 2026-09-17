// Leader mode: after the leader chord, a modify event tap consumes every key
// down until a command runs, Escape, a click, Cmd-Tab, or the idle timeout. The
// tap callback only updates state and consumes; rendering and commands run on
// the next run-loop turn so Accessibility work never sits in the event path.
// Key-ups pass through: the leader chord is a Carbon hotkey, and Carbon counts
// it as held until macOS sees the key-up, ignoring the next press meanwhile.
// The tap is off while a command runs: the providers switch Desktops by posting
// keystrokes, which the tap would otherwise swallow.
// Fn is ignored in leader chords because macOS sets it on arrow keys itself.
import type {HS} from "../api/hs.ts";
import type {Timers} from "../api/timers.ts";
import type {Command, Menu, MenuEntry} from "./commands.ts";
import type {Panel, PanelContent, PanelRow} from "./hud.ts";
import {type Chord, describe, eventChord} from "./keys.ts";

export interface LeaderOptions {
  chord: Chord;
  /** Seconds before the HUD appears; 0 shows it at once. */
  delay: number;
  /** Seconds of inactivity that end leader mode; null never ends it. */
  timeout: number | null;
}

export interface LeaderHooks {
  /** Runs before a render reads availability and hints, off the key-event path; returns the cleanup. */
  prepare(): () => void;
  /** The global shortcut and native hint shown beside a command, if any. */
  hint(command: Command): string | null;
  /** Runs the command if available; resolves to "done" or to feedback that keeps the menu open. */
  execute(command: Command): Promise<"done" | string>;
}

/** How long footer feedback replaces the hints. */
export const feedbackSeconds = 1.5;
const tapMessage = "Could not start the leader event tap; check Accessibility permission";

export class Leader {
  private readonly hs: HS;
  private readonly timers: Timers;
  private readonly panel: Panel;
  private readonly options: LeaderOptions;
  private readonly hooks: LeaderHooks;
  private root: Menu = {label: "Atelier", entries: []};
  private tap: HSEventTap | null = null;
  private active = false;
  private generation = 0;
  private path: MenuEntry[] = [];
  private shown = false;
  /** The leader's own modifiers are ignored until the user releases them once. */
  private heldLeader = false;
  private feedback: string | null = null;
  private timeout: HSTimer | null = null;
  private delay: HSTimer | null = null;
  private feedbackTimer: HSTimer | null = null;

  constructor(hs: HS, timers: Timers, panel: Panel, options: LeaderOptions, hooks: LeaderHooks) {
    this.hs = hs;
    this.timers = timers;
    this.panel = panel;
    this.options = options;
    this.hooks = hooks;
  }

  get isActive(): boolean {
    return this.active;
  }

  /** The current menu path, for status and tests. */
  get location(): string[] {
    return this.path.map((entry) => describe(entry.chord));
  }

  /** Creates the tap without starting it; throws when the tap cannot exist. */
  start(root: Menu): void {
    this.root = root;
    const types = this.hs.eventtap.eventTypes;
    const wanted = [
      "keyDown",
      "keyUp",
      "flagsChanged",
      "leftMouseDown",
      "rightMouseDown",
      "otherMouseDown",
    ];
    const numbers = wanted.map((name) => {
      const type = types[name];
      if (type === undefined) throw new Error("Unknown event type: " + name);
      return type;
    });
    this.tap = this.hs.eventtap.addWatcher(numbers, (event) => this.handle(event), false);
    // HS2 creates the native tap in start(); prove it once now, then keep it off.
    if (!this.tap) throw new Error(tapMessage);
    if (!this.tap.start().isEnabled()) {
      this.stop();
      throw new Error(tapMessage);
    }
    this.tap.stop();
  }

  enter(): void {
    if (!this.tap) return;
    if (this.active) {
      this.path = [];
      this.schedule(() => this.render());
      return;
    }
    this.active = true;
    this.generation++;
    this.path = [];
    this.feedback = null;
    this.heldLeader = true;
    this.shown = this.options.delay <= 0;
    if (!this.tap.start().isEnabled()) {
      this.active = false;
      throw new Error(tapMessage);
    }
    this.resetTimeout();
    if (this.shown) this.schedule(() => this.render());
    else this.delay = this.timers.after(this.options.delay, () => this.show());
  }

  /** The canvas is destroyed rather than hidden: a hidden all-Spaces window
   *  keeps its old placement when the next leader press comes on another Desktop. */
  exit(): void {
    if (!this.active) return;
    this.active = false;
    this.generation++;
    this.tap?.stop();
    this.timers.remove(this.timeout);
    this.timers.remove(this.delay);
    this.timers.remove(this.feedbackTimer);
    this.timeout = this.delay = this.feedbackTimer = null;
    this.path = [];
    this.feedback = null;
    this.panel.destroy();
  }

  stop(): void {
    this.exit();
    if (this.tap) this.hs.eventtap.removeWatcher(this.tap);
    this.tap = null;
  }

  private get menu(): Menu {
    return this.path.at(-1)?.menu ?? this.root;
  }

  private schedule(work: () => void): void {
    const generation = this.generation;
    this.timers.after(0, () => {
      if (this.active && this.generation === generation) work();
    });
  }

  private resetTimeout(): void {
    this.timers.remove(this.timeout);
    this.timeout =
      this.options.timeout === null
        ? null
        : this.timers.after(this.options.timeout, () => this.exit());
  }

  private show(): void {
    this.shown = true;
    this.render();
  }

  private handle(event: HSEventTapEvent): boolean {
    const eventtap = this.hs.eventtap,
      types = eventtap.eventTypes;
    if (!this.active) return eventtap.emit;
    if (event.type === types.flagsChanged) {
      if (this.heldLeader && !this.options.chord.mods.some((mod) => event.flags.includes(mod)))
        this.heldLeader = false;
      return eventtap.emit;
    }
    if (event.type !== types.keyDown && event.type !== types.keyUp) {
      // Any click ends leader mode and lands where it was aimed.
      this.exit();
      return eventtap.emit;
    }
    const key = String(this.hs.keycodes.map[String(event.keyCode)] ?? ""),
      flags = event.flags.filter((flag) => flag !== "fn"),
      raw = eventChord(flags, key);
    if (raw.mods.includes("cmd") && raw.key === "tab") {
      this.exit();
      return eventtap.emit;
    }
    // A key-up without its key-down does nothing in an app; a consumed one
    // leaves the leader hotkey pressed as far as Carbon knows.
    if (event.type === types.keyUp) return eventtap.emit;
    this.resetTimeout();
    if (raw.identity === this.options.chord.identity) {
      this.path = [];
      this.schedule(() => this.render());
      return eventtap.consume;
    }
    const pressed = this.heldLeader
      ? eventChord(
          flags.filter((flag) => !this.options.chord.mods.includes(flag)),
          key,
        )
      : raw;
    if (!pressed.mods.length && pressed.key === "escape") {
      this.exit();
      return eventtap.consume;
    }
    if (!pressed.mods.length && pressed.key === "delete") {
      this.path.pop();
      this.schedule(() => this.render());
      return eventtap.consume;
    }
    const entry = this.menu.entries.find((e) => e.chord.identity === pressed.identity);
    if (!entry) {
      const name = key ? "No command for " + describe(pressed) : "Unknown key";
      this.schedule(() => this.explain(name));
    } else if (entry.menu) {
      this.path.push(entry);
      this.schedule(() => this.render());
    } else {
      this.schedule(() => this.run(entry.command));
    }
    return eventtap.consume;
  }

  /** Runs the command with the tap off, so keystrokes the command posts reach
   *  macOS; feedback that keeps the menu open turns the tap back on. */
  private async run(command: Command): Promise<void> {
    const generation = this.generation;
    this.tap?.stop();
    const outcome = await this.hooks.execute(command);
    if (!this.active || this.generation !== generation) return;
    if (outcome === "done") {
      this.exit();
      return;
    }
    if (!this.tap?.start().isEnabled()) {
      this.exit();
      console.error("Atelier: " + tapMessage);
      return;
    }
    this.explain(outcome);
  }

  /** Shows brief feedback in the footer, revealing the HUD if the delay has not elapsed. */
  private explain(text: string): void {
    this.feedback = text;
    this.timers.remove(this.feedbackTimer);
    this.feedbackTimer = this.timers.after(feedbackSeconds, () => {
      this.feedback = null;
      this.render();
    });
    this.timers.remove(this.delay);
    this.delay = null;
    this.show();
  }

  private render(): void {
    if (!this.active || !this.shown) return;
    const done = this.hooks.prepare();
    try {
      this.draw();
    } finally {
      done();
    }
  }

  private draw(): void {
    const menu = this.menu;
    const rows: PanelRow[] = menu.entries.map((entry) => {
      if (entry.menu) return {key: describe(entry.chord), label: entry.menu.label, hint: "›"};
      const reason = entry.command.available?.() ?? null;
      return {
        key: describe(entry.chord),
        label: entry.command.label,
        hint: this.hooks.hint(entry.command) ?? undefined,
        dim: reason !== null,
      };
    });
    const hints = this.path.length ? "Esc closes · ⌫ back" : "Esc closes";
    const content: PanelContent = {
      title: this.path.length
        ? this.path.map((entry) => entry.menu?.label ?? "").join(" › ")
        : this.root.label,
      rows,
      footer: this.feedback ?? hints,
    };
    // The same corner as the window list: both are one HUD showing what the
    // keyboard can do right now.
    const screen = this.hs.screen.main() ?? this.hs.screen.primary();
    if (!screen) return;
    this.panel.show(content, {screen: screen.frame, key: "leader:" + screen.uuid});
  }
}
