// Groups key on PID/window and display/Space identities, which survive Reload
// Config and a Hammerspoon 2 relaunch but not a restart. Reconcile only visible
// Desktops: inventories cannot establish membership on inactive Spaces.
//
// A Group's slots are its live members, kept compact and in order, plus the
// waiting slots of a preset whose apps have not shown a window yet. A waiting
// slot holds its position in the combined list so an arrival takes that
// number even when a later app arrived first. Waiting slots are session
// state: they are neither saved nor restored.
import type {Frame, Snapshot, WindowInfo} from "../api/spaces.ts";
import type {SavedGroup, SavedMember} from "./state.ts";

export interface Member extends WindowInfo {
  fillFailed?: boolean;
  filledFrame?: Frame;
}

export interface WaitingSlot {
  bundleID: string;
  app: string;
  /** Zero-based position among all slots, live and waiting. */
  position: number;
}

export interface Group {
  display: string;
  space: string;
  members: Member[];
  waiting: WaitingSlot[];
}

export type Slot = Member | WaitingSlot;

export const identity = (window: {pid: number; id: number}): string => window.pid + ":" + window.id;

export const isMember = (slot: Slot): slot is Member => "id" in slot;

/** Every slot in display order: live members, with waiting slots at their positions. */
export function slots(group: Group): Slot[] {
  const result: Slot[] = [];
  let next = 0;
  for (let position = 0; position < group.members.length + group.waiting.length; position++) {
    const waiting = group.waiting.find((slot) => slot.position === position);
    const slot = waiting ?? group.members[next++];
    if (slot) result.push(slot);
  }
  return result;
}

/** A move request: a relative offset, or an object naming the final one-based slot. */
export type MoveTarget = number | {slot: number};

/** Checks a move request from configuration or the Console; nothing is coerced. */
export function moveTarget(value: unknown): MoveTarget {
  if (typeof value === "number" && Number.isInteger(value)) return value;
  const slot =
    value &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).join() === "slot"
      ? (value as {slot: unknown}).slot
      : undefined;
  if (typeof slot === "number" && Number.isInteger(slot) && slot > 0) return {slot};
  throw new Error("A move target must be a whole-number offset or {slot: n} with n at least 1");
}

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
      // A reused process or window ID from another app is a different window.
      const list = slots(group).filter(
        (slot) => !isMember(slot) || found.get(identity(slot))?.bundleID === slot.bundleID,
      );
      for (const slot of list) {
        if (!isMember(slot)) continue;
        Object.assign(slot, found.get(identity(slot)));
        found.delete(identity(slot));
      }
      // A new window takes the first waiting slot for its app, otherwise the end.
      for (const window of found.values()) {
        const index = list.findIndex((s) => !isMember(s) && s.bundleID === window.bundleID);
        if (index < 0) list.push({...window});
        else list[index] = {...window};
      }
      this.assign(group, list);
    }
    for (const [key, group] of this.entries) {
      if (!alive.has(key) || (!group.members.length && !group.waiting.length))
        this.entries.delete(key);
    }
  }

  /** Stores an ordered slot list as compact members and repositioned waiting slots. */
  private assign(group: Group, list: Slot[]) {
    group.members = list.filter(isMember);
    group.waiting = list.flatMap((slot, position) => (isMember(slot) ? [] : [{...slot, position}]));
  }

  /** The ordinary Desktop on the target display, with its inventory. */
  private desktop(snapshot: Snapshot): {display: string; space: string; windows: WindowInfo[]} {
    const display = snapshot.displays.find((d) => d.id === snapshot.targetDisplay);
    if (!display?.spaces.some((s) => s.id === display.current && !s.fullscreen))
      throw new Error("Select an ordinary Desktop first");
    return {
      display: display.id,
      space: display.current,
      windows: snapshot.windows.filter((w) => w.space === display.current),
    };
  }

  /** Creates a Group from the Desktop's windows, the focused one first. */
  create(snapshot: Snapshot): Group {
    this.reconcile(snapshot);
    const {display, space, windows} = this.desktop(snapshot);
    windows.sort((a, b) => Number(b.id === snapshot.focused) - Number(a.id === snapshot.focused));
    if (!windows.length) throw new Error("No eligible windows on this Desktop");
    const group = {display, space, members: windows.map((w) => ({...w})), waiting: []};
    this.entries.set(this.key(display, space), group);
    return group;
  }

  /** Registers an empty Group on an empty Desktop for `wait` to fill. */
  expect(snapshot: Snapshot): Group {
    const {display, space, windows} = this.desktop(snapshot);
    if (windows.length)
      throw new Error("Group presets need an empty Desktop; create one and try again");
    if (this.entries.has(this.key(display, space)))
      throw new Error("This Desktop is already waiting for a Group preset");
    const group = {display, space, members: [], waiting: []};
    this.entries.set(this.key(display, space), group);
    return group;
  }

  /** Adds a waiting slot after every slot so far. */
  wait(group: Group, app: {bundleID: string; app: string}): void {
    group.waiting.push({...app, position: group.members.length + group.waiting.length});
  }

  /** Gives up every waiting slot; the live members close ranks. Returns the app names. */
  expire(group: Group): string[] {
    const names = group.waiting.map((slot) => slot.app);
    group.waiting = [];
    if (!group.members.length) this.forget(group);
    return names;
  }

  forget(group: Group): void {
    const key = this.key(group.display, group.space);
    if (this.entries.get(key) === group) this.entries.delete(key);
  }

  /** Moves `member` to a new position in `group`, keeping the others in their
   *  relative order. Returns false when nothing changed: the member is absent,
   *  the destination is its current slot, or the move would pass an edge. */
  move(group: Group, member: Member, target: MoveTarget): boolean {
    const from = group.members.indexOf(member),
      last = group.members.length - 1;
    if (from < 0) return false;
    const requested = typeof target === "number" ? from + target : target.slot - 1;
    const to = Math.max(0, Math.min(last, requested));
    if (to === from) return false;
    group.members.splice(from, 1);
    group.members.splice(to, 0, member);
    return true;
  }

  /** The identities and Fill frames worth keeping across a reload; titles and
   *  frames come from the live snapshot, and a reload retries failed Fills. */
  serialize(): SavedGroup[] {
    return [...this.entries.values()].map((group) => ({
      display: group.display,
      space: group.space,
      members: group.members.map((m) => ({
        pid: m.pid,
        id: m.id,
        app: m.app,
        bundleID: m.bundleID,
        ...(m.filledFrame ? {filledFrame: {...m.filledFrame}} : {}),
      })),
    }));
  }

  /** Replaces every Group with the saved ones whose Desktop still exists and
   *  that `alive` confirms for at least one member, then reconciles visible
   *  Desktops. Display and Space IDs can repeat after a restart, so a saved
   *  window must still exist somewhere or the Group is not the one saved. */
  restore(
    saved: SavedGroup[],
    snapshot: Snapshot,
    alive: (member: SavedMember) => boolean,
  ): {restored: number; dropped: number} {
    this.entries.clear();
    for (const group of saved) {
      if (!group.members.some(alive)) continue;
      this.entries.set(this.key(group.display, group.space), {
        display: group.display,
        space: group.space,
        members: group.members.map((m) => ({
          id: m.id,
          pid: m.pid,
          space: group.space,
          frame: {x: 0, y: 0, w: 0, h: 0},
          title: "",
          app: m.app,
          bundleID: m.bundleID,
          ...(m.filledFrame ? {filledFrame: {...m.filledFrame}} : {}),
        })),
        waiting: [],
      });
    }
    this.reconcile(snapshot);
    const dropped = saved.filter((g) => !this.entries.has(this.key(g.display, g.space))).length;
    return {restored: this.entries.size, dropped};
  }
}
