"use strict";
// HS2 0.0.12 canvas positions use AppKit's y-up coordinates; screen frames use
// y-down coordinates. Input event flags are reliable on this pinned build.
// Each canvas belongs to one display/Space; hiding retains HS2's native window.
const white = (alpha) => ({red: 1, green: 1, blue: 1, alpha});
function frameFor(screen, primary, width, height) {
  return {
    x: screen.x + screen.w - width - 20,
    y: primary.h - screen.y - screen.h + 20,
    w: width,
    h: height,
  };
}
class Overlay {
  constructor(hs, flags, refresh) {
    this.hs = hs;
    this.flags = flags;
    this.refresh = refresh;
    this.active = false;
  }
  start() {
    const events = this.hs.eventtap.eventTypes;
    this.tap = this.hs.eventtap.addWatcher(
      [events.flagsChanged, events.keyDown, events.keyUp, events.leftMouseDown],
      (event) => {
        const flags = event.flags;
        const active =
          this.flags.every((f) => flags.includes(f)) &&
          ["cmd", "alt", "ctrl", "shift"].every(
            (f) => !flags.includes(f) || this.flags.includes(f),
          );
        if (active !== this.active) {
          this.active = active;
          if (active) this.refresh();
          else this.hide();
        }
        return this.hs.eventtap.emit;
      },
      true,
    );
    if (!this.tap)
      throw new Error("Could not observe overlay modifiers; check Accessibility permission");
    this.tap.start();
  }
  hide() {
    if (this.canvas) this.canvas.hide();
    this.signature = null;
  }
  update(snapshot, group) {
    if (!this.active || !group?.members.length || snapshot.missionControl) {
      this.hide();
      return;
    }
    const primary = this.hs.screen.primary();
    const screen =
      group.display === "Main"
        ? primary
        : this.hs.screen.all().find((s) => s.uuid.toUpperCase() === group.display.toUpperCase());
    if (!screen || !primary) {
      this.hide();
      return;
    }
    const canvasGroup = JSON.stringify([group.display, group.space]);
    if (canvasGroup !== this.canvasGroup) {
      // Recreate on the target Desktop instead of relying on a hidden window's
      // all-Spaces behavior to carry its previous placement across Desktops.
      if (this.canvas) this.canvas.destroy();
      this.canvas = null;
      this.signature = null;
      this.canvasGroup = canvasGroup;
    }
    const focus = this.hs.window.focusedWindow(),
      usable = screen.frame;
    const rows = Math.max(1, Math.floor((usable.h - 120) / 42));
    const columns = Math.ceil(group.members.length / rows),
      width = Math.min(320 * columns, usable.w - 40);
    const height = 68 + Math.min(rows, group.members.length) * 42,
      column = width / columns;
    const frame = frameFor(usable, primary.fullFrame, width, height);
    const signature = JSON.stringify([
      frame,
      focus && [focus.pid, focus.id],
      group.members.map((m) => [m.pid, m.id, m.title]),
    ]);
    if (signature === this.signature) return;
    const text = (value, x, y, w, size, alpha = 1) => ({
      type: "text",
      text: String(value).replace(/\s+/g, " "),
      frame: {x, y, w, h: size + 6},
      textSize: size,
      textColor: white(alpha),
      textLineBreak: "truncateTail",
    });
    const elements = [
      {
        type: "rectangle",
        action: "fill",
        frame: {x: 0, y: 0, w: width, h: height},
        roundedRectRadii: {xRadius: 14, yRadius: 14},
        fillColor: {red: 0.08, green: 0.09, blue: 0.12, alpha: 0.96},
      },
      text("GROUP WINDOWS", 18, 12, width - 36, 11, 0.6),
    ];
    const counts = new Map();
    for (const member of group.members) counts.set(member.app, (counts.get(member.app) || 0) + 1);
    group.members.forEach((member, index) => {
      const x = Math.floor(index / rows) * column,
        y = 36 + (index % rows) * 42;
      if (focus && focus.pid === member.pid && focus.id === member.id)
        elements.push({
          type: "rectangle",
          action: "fill",
          frame: {x: x + 8, y: y - 2, w: column - 16, h: 38},
          roundedRectRadii: {xRadius: 7, yRadius: 7},
          fillColor: {red: 0.2, green: 0.4, blue: 0.8, alpha: 0.5},
        });
      const duplicate = counts.get(member.app) > 1;
      elements.push(
        text(index === 9 ? 0 : index + 1, x + 18, y + 5, 28, 14, index < 10 ? 1 : 0.45),
      );
      elements.push(text(member.app, x + 52, y + (duplicate ? 0 : 5), column - 66, 14));
      if (duplicate)
        elements.push(text(member.title || "Untitled", x + 52, y + 18, column - 66, 10, 0.6));
    });
    elements.push(text("Release modifiers to hide", 18, height - 24, width - 36, 11, 0.5));
    if (!this.canvas)
      this.canvas = this.hs.canvas
        .create(frame)
        .level("floating")
        .behaviorList(["canJoinAllSpaces", "stationary", "ignoresCycle"])
        .clickActivating(false)
        .ignoreMouseEvents(true);
    this.canvas.setFrame(frame).replaceElements(elements).show();
    this.signature = signature;
  }
  stop() {
    if (this.tap) this.hs.eventtap.removeWatcher(this.tap);
    if (this.canvas) this.canvas.destroy();
    this.tap = this.canvas = null;
    this.active = false;
    this.signature = this.canvasGroup = null;
  }
}
module.exports = {Overlay, frameFor};
