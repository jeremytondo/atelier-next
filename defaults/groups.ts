// Groups use session-only PID/window and display/Space identities. Reconcile only
// visible Desktops: inventories cannot establish membership on inactive Spaces.
import type {Frame, Snapshot, WindowInfo} from "../api/spaces.ts";

export interface Member extends WindowInfo {
  fillFailed?: boolean;
  filledFrame?: Frame;
}

export interface Group {
  display: string;
  space: string;
  members: Member[];
}

export const identity = (window: {pid: number; id: number}): string => window.pid + ":" + window.id;

export const sameFrame = (
  a: Frame | null | undefined,
  b: Frame | null | undefined,
  tolerance = 1,
): boolean =>
  !!a && !!b && (["x", "y", "w", "h"] as const).every((k) => Math.abs(a[k] - b[k]) <= tolerance);

export class Groups {
  readonly entries = new Map<string, Group>();

  key(display: string, space: string): string {
    return display + ":" + space;
  }

  current(snapshot: Snapshot): Group | undefined {
    const display = snapshot.displays.find((d) => d.id === snapshot.targetDisplay);
    return display && this.entries.get(this.key(display.id, display.current));
  }

  reconcile(snapshot: Snapshot): void {
    const alive = new Set<string>();
    for (const display of snapshot.displays) {
      for (const space of display.spaces) alive.add(this.key(display.id, space.id));
      const group = this.entries.get(this.key(display.id, display.current));
      if (!group) continue;
      const windows = snapshot.windows.filter((w) => w.space === display.current);
      const found = new Map(windows.map((w) => [identity(w), w]));
      group.members = group.members.filter((w) => found.has(identity(w)));
      for (const member of group.members) {
        Object.assign(member, found.get(identity(member)));
        found.delete(identity(member));
      }
      group.members.push(...[...found.values()].map((w) => ({...w})));
    }
    for (const key of this.entries.keys()) if (!alive.has(key)) this.entries.delete(key);
  }

  repair(snapshot: Snapshot): Group {
    this.reconcile(snapshot);
    const display = snapshot.displays.find((d) => d.id === snapshot.targetDisplay);
    if (!display?.spaces.some((s) => s.id === display.current && !s.fullscreen))
      throw new Error("Select an ordinary Desktop first");
    let group = this.current(snapshot);
    if (!group) {
      const windows = snapshot.windows.filter((w) => w.space === display.current);
      windows.sort((a, b) => Number(b.id === snapshot.focused) - Number(a.id === snapshot.focused));
      if (!windows.length) throw new Error("No eligible windows on this Desktop");
      group = {display: display.id, space: display.current, members: windows.map((w) => ({...w}))};
      this.entries.set(this.key(display.id, display.current), group);
    }
    for (const member of group.members) member.fillFailed = false;
    return group;
  }
}
