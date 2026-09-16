// The window list HUD: shown while the overlay modifiers are held, on the
// display of the focused Desktop, and redrawn as the list changes. Shift may
// join the chord so the move shortcuts can be pressed while the list is
// visible; any other extra modifier is a different chord.
import type {HS} from "../api/hs.ts";
import {Panel, type PanelRow} from "./hud.ts";
import {type DesktopWindows, isWindow, windowsOf} from "./windows.ts";

export class Overlay {
  private readonly hs: HS;
  private readonly flags: string[];
  private readonly refresh: () => void;
  private readonly panel: Panel;
  private active = false;
  private tap: HSEventTap | null = null;

  constructor(hs: HS, flags: string[], refresh: () => void) {
    this.hs = hs;
    this.flags = flags;
    this.refresh = refresh;
    this.panel = new Panel(hs);
  }

  start(): void {
    const events = this.hs.eventtap.eventTypes;
    const types = ["flagsChanged", "keyDown", "keyUp", "leftMouseDown"].map((name) => {
      const type = events[name];
      if (type === undefined) throw new Error("Unknown event type: " + name);
      return type;
    });
    this.tap = this.hs.eventtap.addWatcher(
      types,
      (event) => {
        const flags = event.flags;
        const active =
          this.flags.every((f) => flags.includes(f)) &&
          ["cmd", "alt", "ctrl"].every((f) => !flags.includes(f) || this.flags.includes(f));
        if (active !== this.active) {
          this.active = active;
          if (active) this.refresh();
          else this.hide();
        }
        return this.hs.eventtap.emit;
      },
      true,
    );
    // HS2 creates the native tap in start(); only an enabled tap observes anything.
    if (!this.tap?.start().isEnabled())
      throw new Error("Could not observe overlay modifiers; check Accessibility permission");
  }

  hide(): void {
    this.panel.hide();
  }

  update(snapshot: {missionControl: boolean}, desktop: DesktopWindows | null | undefined): void {
    const list = desktop?.slots ?? [];
    if (!this.active || !desktop || !list.length || snapshot.missionControl) {
      this.hide();
      return;
    }
    const screen =
      desktop.display === "Main"
        ? this.hs.screen.primary()
        : this.hs.screen.all().find((s) => s.uuid.toUpperCase() === desktop.display.toUpperCase());
    if (!screen) {
      this.hide();
      return;
    }
    const focus = this.hs.window.focusedWindow(),
      usable = screen.frame;
    const counts = new Map<string, number>();
    for (const window of windowsOf(desktop))
      counts.set(window.app, (counts.get(window.app) || 0) + 1);
    const rows: PanelRow[] = list.map((slot, index) => {
      const key = String(index === 9 ? 0 : index + 1);
      // A preset app that has not shown a window yet keeps its number, dimmed,
      // as do hidden and minimized windows.
      if (!isWindow(slot)) return {key, label: slot.app, dim: true};
      const duplicate = (counts.get(slot.app) ?? 0) > 1;
      return {
        key,
        label: slot.app,
        ...(duplicate ? {detail: slot.title || "Untitled"} : {}),
        dim: !slot.visible,
        highlight: !!focus && focus.pid === slot.pid && focus.id === slot.id,
      };
    });
    const perColumn = Math.max(1, Math.floor((usable.h - 120) / 42));
    this.panel.show(
      {
        title: "Windows",
        rows,
        footer: "Release modifiers to hide",
        columns: Math.ceil(rows.length / perColumn),
        columnWidth: 320,
      },
      {
        screen: usable,
        anchor: "bottomRight",
        key: JSON.stringify([desktop.display, desktop.space]),
      },
    );
  }

  stop(): void {
    if (this.tap) this.hs.eventtap.removeWatcher(this.tap);
    this.tap = null;
    this.active = false;
    this.panel.destroy();
  }
}
