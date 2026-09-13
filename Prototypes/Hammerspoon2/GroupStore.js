"use strict";

// Session identities only. Space IDs are strings to avoid UInt64 precision loss.
class GroupStore {
  constructor() { this.groups = new Map(); }
  key(display, space) { return `${display}:${space}`; }
  reconcile(snapshot) {
    const existing = new Set();
    for (const display of snapshot.displays) {
      for (const space of display.spaces) existing.add(this.key(display.id, space.id));
      const group = this.groups.get(this.key(display.id, display.current));
      if (!group) continue; // Off-Space observations can be incomplete.
      const windows = snapshot.windows.filter(w => w.space === display.current);
      const ids = new Set(windows.map(w => `${w.pid}:${w.id}`));
      group.members = group.members.filter(w => ids.has(`${w.pid}:${w.id}`));
      for (const window of windows) {
        const member = group.members.find(w => w.id === window.id && w.pid === window.pid);
        if (member) Object.assign(member, window);
        else group.members.push({...window, filledFrame: null, fillFailed: false});
      }
    }
    for (const key of this.groups.keys()) if (!existing.has(key)) this.groups.delete(key);
  }
  current(snapshot) {
    const display = snapshot.displays.find(d => d.id === snapshot.targetDisplay);
    return display && this.groups.get(this.key(display.id, display.current));
  }
  group(snapshot) {
    this.reconcile(snapshot);
    const display = snapshot.displays.find(d => d.id === snapshot.targetDisplay);
    if (!display || !display.spaces.some(s => s.id === display.current && !s.fullscreen)) {
      throw new Error("An ordinary Desktop must be active");
    }
    const key = this.key(display.id, display.current);
    if (!this.groups.has(key)) {
      const windows = snapshot.windows.filter(w => w.space === display.current);
      windows.sort((a, b) => Number(b.id === snapshot.focused) - Number(a.id === snapshot.focused));
      if (!windows.length) throw new Error("No eligible windows on this Desktop");
      this.groups.set(key, {display: display.id, space: display.current,
        members: windows.map(w => ({...w, filledFrame: null, fillFailed: false}))});
    }
    const group = this.groups.get(key);
    for (const member of group.members) member.fillFailed = false;
    return group;
  }
  moveMember(group, id, offset) {
    const from = group.members.findIndex(w => w.id === id);
    const to = from + offset;
    if (from < 0 || to < 0 || to >= group.members.length) return;
    group.members.splice(to, 0, group.members.splice(from, 1)[0]);
  }
}

function sameFrame(a, b, tolerance = 1) {
  return !!a && !!b && ["x", "y", "w", "h"].every(k => Math.abs(a[k] - b[k]) <= tolerance);
}

module.exports = {GroupStore, sameFrame};
