"use strict";

const held = flags => flags.includes("cmd") && flags.includes("alt") &&
  !flags.includes("ctrl") && !flags.includes("shift");
// HS2's canvas parser accepts RGB components; v1's `white` shorthand renders black.
const white = alpha => ({red: 1, green: 1, blue: 1, alpha});
const clean = value => String(value || "").replace(/\s+/g, " ").trim();

// HS2 0.0.12: canvas windows use AppKit (y-up), screen frames use y-down.
function panelFrame(usable, primaryHeight, width, height) {
  return {x: usable.x + usable.w - width - 20,
    y: primaryHeight - usable.y - usable.h + 20, w: width, h: height};
}

module.exports = class GroupOverlay {
  constructor(hs, onHold) {
    this.hs = hs;
    this.onHold = onHold;
    this.active = false;
    this.canvas = null;
    this.signature = null;
    this.tap = null;
    // Timestamped highlight changes, for measuring overlay lag against focus.
    this.renders = [];
  }
  start() {
    const hs = this.hs;
    // In HS2 0.0.12 currentModifiers() can report [] while an event correctly
    // carries cmd+alt. Use event flags for both press and release. Other input
    // resynchronizes the state if a modifier release was missed during sleep.
    const types = hs.eventtap.eventTypes;
    this.tap = hs.eventtap.addWatcher([types.flagsChanged, types.keyDown, types.keyUp,
      types.leftMouseDown, types.rightMouseDown], event => {
      this.modifiers(event.flags);
      return hs.eventtap.emit;
    }, true);
    if (!this.tap) throw new Error("Could not watch Group overlay modifiers");
    this.tap.start();
  }
  modifiers(flags) {
    const active = held(flags);
    if (active === this.active) return;
    this.active = active;
    if (active) this.onHold();
    else this.hide();
  }
  hide() {
    if (this.canvas) this.canvas.hide();
    this.signature = null;
  }
  update(snapshot, group) {
    const hs = this.hs;
    if (!this.active ||
        !group || !group.members.length || snapshot.missionControl) {
      this.hide(); return;
    }
    const primary = hs.screen.primary();
    const screen = group.display === "Main" ? primary : hs.screen.all().find(s =>
      s.uuid.toUpperCase() === String(group.display).toUpperCase());
    if (!screen || !primary) { this.hide(); return; }
    const members = group.members, usable = screen.frame;
    const rows = Math.max(1, Math.floor((usable.h - 120) / 42));
    const columns = Math.ceil(members.length / rows);
    const width = Math.min(320 * columns, usable.w - 40);
    const columnWidth = width / columns;
    const height = 76 + Math.min(rows, members.length) * 42;
    const rect = panelFrame(usable, primary.fullFrame.h, width, height);
    const focused = hs.window.focusedWindow();
    const signature = JSON.stringify([rect, group.space, focused && focused.id,
      members.map(m => [m.id, m.pid, m.app, m.title])]);
    if (signature === this.signature) return;
    const text = (value, x, y, w, size, alpha = 1) => ({type:"text", text:value,
      frame:{x, y, w, h:size + 6}, textSize:size, textColor:white(alpha),
      textLineBreak:"truncateTail"});
    const elements = [
      {type:"rectangle", action:"fill", roundedRectRadii:{xRadius:14, yRadius:14},
        fillColor:{red:0.09, green:0.09, blue:0.09, alpha:0.96}, frame:{x:0, y:0, w:width, h:height}},
      text("GROUP WINDOWS", 18, 14, width - 36, 11, 0.55),
      text("⌘⌥  +  number     ·     [ / ] to cycle", 18, height - 27, width - 36, 11, 0.55)
    ];
    const counts = new Map();
    for (const m of members) counts.set(m.app, (counts.get(m.app) || 0) + 1);
    members.forEach((m, index) => {
      const x = Math.floor(index / rows) * columnWidth, y = 38 + (index % rows) * 42;
      if (focused && m.id === focused.id && m.pid === focused.pid) {
        elements.push({type:"rectangle", action:"fill", roundedRectRadii:{xRadius:7, yRadius:7},
          fillColor:{red:0.28, green:0.48, blue:0.9, alpha:0.4},
          frame:{x:x+9, y:y-2, w:columnWidth-18, h:38}});
      }
      const duplicate = counts.get(m.app) > 1;
      // 0 is the tenth shortcut. Later members are available via cycling only.
      elements.push(text(String(index === 9 ? 0 : index + 1), x+19, y+5, 28, 14, index < 10 ? 1 : 0.45));
      elements.push(text(clean(m.app) || "Unknown app", x+55, y+(duplicate ? 0 : 5), columnWidth-72, 14));
      if (duplicate) elements.push(text(clean(m.title) || "Untitled window", x+55, y+18, columnWidth-72, 10, 0.55));
    });
    if (!this.canvas) {
      this.canvas = hs.canvas.create(rect);
      this.canvas.level("floating").behaviorList(["canJoinAllSpaces", "stationary", "ignoresCycle"])
        .clickActivating(false).ignoreMouseEvents(true);
    }
    this.canvas.setFrame(rect).replaceElements(elements).show();
    this.signature = signature;
    this.renders.push({focused: focused ? focused.id : null, at: Date.now()});
    if (this.renders.length > 40) this.renders.shift();
  }
  stop() {
    this.active = false;
    if (this.tap) this.hs.eventtap.removeWatcher(this.tap);
    if (this.canvas) this.canvas.destroy();
    this.tap = this.canvas = this.signature = null;
  }
};
module.exports.panelFrame = panelFrame;
