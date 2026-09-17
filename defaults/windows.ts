// Every ordinary Desktop keeps an ordered list of its windows, keyed by the
// native display and Space identities, which survive Reload Config and a
// Hammerspoon 2 relaunch but not a restart. Membership follows macOS: a window
// is listed on every Desktop it belongs to, and each list owns its order.
//
// The provider combines WindowServer membership with Accessibility to exclude
// closed windows that WindowServer still retains. A window missing from that
// census has closed; one whose membership names other Desktops has left.
// Accessibility's ordinary-window verdict only admits windows, since it can
// miss inactive windows or misreport hidden ones.
//
// A list's slots are its windows plus the waiting slots of a preset whose apps
// have not shown a window yet; a waiting slot keeps its number until the app's
// window arrives or the wait expires. Waiting slots are session state, neither
// saved nor restored.
import type {Snapshot, WindowInfo} from "../api/spaces.ts";
import type {SavedDesktop, SavedWindow} from "./state.ts";

export interface ListedWindow extends SavedWindow {
  title: string;
  /** On screen now: neither hidden, minimized, nor on an inactive Desktop. */
  visible: boolean;
}

export interface WaitingSlot {
  bundleID: string;
  app: string;
}

export type Slot = ListedWindow | WaitingSlot;

export interface DesktopWindows {
  display: string;
  space: string;
  slots: Slot[];
}

/** One window: its ID, its process, and that process's launch, which a restart cannot recycle. */
export const identity = (window: {pid: number; id: number; launched: number}): string =>
  window.pid + ":" + window.id + ":" + window.launched;

export const isWindow = (slot: Slot): slot is ListedWindow => "id" in slot;

/** The windows that have arrived, in slot order. */
export const windowsOf = (list: DesktopWindows): ListedWindow[] => list.slots.filter(isWindow);

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

const listed = (window: WindowInfo): ListedWindow => ({
  id: window.id,
  pid: window.pid,
  launched: window.launched,
  app: window.app,
  bundleID: window.bundleID,
  title: window.title,
  visible: window.onScreen,
});

export class WindowLists {
  readonly entries = new Map<string, DesktopWindows>();

  key(display: string, space: string): string {
    return display + ":" + space;
  }

  /** The ordinary Desktop that receives keyboard input; undefined on a fullscreen Space. */
  focusedDesktop(snapshot: Snapshot): {display: string; space: string} | undefined {
    for (const display of snapshot.displays) {
      const space = display.spaces.find((s) => s.id === snapshot.focusedSpace);
      if (space) return space.fullscreen ? undefined : {display: display.id, space: space.id};
    }
    return undefined;
  }

  /** The focused Desktop's list; undefined when it has none yet or the Space is fullscreen. */
  focused(snapshot: Snapshot): DesktopWindows | undefined {
    const desktop = this.focusedDesktop(snapshot);
    return desktop && this.entries.get(this.key(desktop.display, desktop.space));
  }

  /** Brings every list up to date with a complete census: arrivals append,
   *  closures and departures compact, and a Desktop seen for the first time
   *  starts with the focused window, then the visible ones front to back,
   *  then the rest. */
  reconcile(snapshot: Snapshot): void {
    const census = new Map(snapshot.windows.map((w) => [identity(w), w]));
    // A window already listed somewhere is ordinary wherever it turns up next,
    // even where Accessibility cannot see it.
    const known = new Set<string>();
    for (const list of this.entries.values())
      for (const window of windowsOf(list)) known.add(identity(window));
    const admitted = (w: WindowInfo) => w.ordinary === true || known.has(identity(w));
    const alive = new Set<string>();
    for (const display of snapshot.displays) {
      for (const {id: space, fullscreen} of display.spaces) {
        if (fullscreen) continue;
        const key = this.key(display.id, space);
        alive.add(key);
        const candidates = snapshot.windows.filter((w) => w.spaces.includes(space) && admitted(w));
        const list = this.entries.get(key);
        if (!list) {
          if (!candidates.length) continue;
          const rank = (w: WindowInfo) => (w.id === snapshot.focused ? 0 : w.onScreen ? 1 : 2);
          candidates.sort((a, b) => rank(a) - rank(b));
          this.entries.set(key, {display: display.id, space, slots: candidates.map(listed)});
          continue;
        }
        // Absent from the census is closed, and the census key rejects a recycled ID;
        // membership naming only other Spaces is a departure. Unknown membership keeps it.
        const retained = (window: ListedWindow) => {
          const live = census.get(identity(window));
          return !!live && (!live.spaces.length || live.spaces.includes(space));
        };
        const current = list.slots.filter((slot) => !isWindow(slot) || retained(slot));
        const found = new Map(candidates.map((w) => [identity(w), w]));
        for (const slot of current) {
          if (!isWindow(slot)) continue;
          const live = census.get(identity(slot));
          if (live) Object.assign(slot, listed(live));
          found.delete(identity(slot));
        }
        // A new window takes the first waiting slot for its app, otherwise the end.
        for (const window of found.values()) {
          const index = current.findIndex((s) => !isWindow(s) && s.bundleID === window.bundleID);
          if (index < 0) current.push(listed(window));
          else current[index] = listed(window);
        }
        list.slots = current;
      }
    }
    for (const [key, list] of this.entries) {
      if (!alive.has(key) || !list.slots.length) this.entries.delete(key);
    }
  }

  /** The focused Desktop's list for a preset: an ordinary Desktop with no
   *  visible window and no slots still waiting. Hidden and minimized windows
   *  may be listed; they do not make the Desktop occupied. */
  prepare(snapshot: Snapshot): DesktopWindows {
    const desktop = this.focusedDesktop(snapshot);
    if (!desktop) throw new Error("Select an ordinary Desktop first");
    const key = this.key(desktop.display, desktop.space);
    const list = this.entries.get(key) ?? {...desktop, slots: []};
    if (list.slots.some((slot) => isWindow(slot) && slot.visible))
      throw new Error("Presets need an empty Desktop; create one and try again");
    if (list.slots.some((slot) => !isWindow(slot)))
      throw new Error("This Desktop is already waiting for a preset");
    this.entries.set(key, list);
    return list;
  }

  /** Numbers a preset's apps in order ahead of everything else listed: an app
   *  with a listed window takes its slot, any other app gets a waiting slot. */
  seed(list: DesktopWindows, apps: WaitingSlot[]): void {
    const named: Slot[] = [],
      rest = [...list.slots];
    for (const app of apps) {
      const index = rest.findIndex((slot) => isWindow(slot) && slot.bundleID === app.bundleID);
      const found = index < 0 ? undefined : rest.splice(index, 1)[0];
      named.push(found ?? {...app});
    }
    list.slots = [...named, ...rest];
  }

  /** Gives up every waiting slot; the windows close ranks. Returns the app names. */
  expire(list: DesktopWindows): string[] {
    const names = list.slots.flatMap((slot) => (isWindow(slot) ? [] : [slot.app]));
    list.slots = windowsOf(list);
    const key = this.key(list.display, list.space);
    if (!list.slots.length && this.entries.get(key) === list) this.entries.delete(key);
    return names;
  }

  /** Moves `window` to a new slot in `list`, keeping the others in their
   *  relative order. Returns false when nothing changed: the window is absent,
   *  the destination is its current slot, or the move would pass an edge. */
  move(list: DesktopWindows, window: ListedWindow, target: MoveTarget): boolean {
    const from = list.slots.indexOf(window),
      last = list.slots.length - 1;
    if (from < 0) return false;
    const requested = typeof target === "number" ? from + target : target.slot - 1;
    const to = Math.max(0, Math.min(last, requested));
    if (to === from) return false;
    list.slots.splice(from, 1);
    list.slots.splice(to, 0, window);
    return true;
  }

  /** The order and identities worth keeping across a reload; titles and
   *  visibility come from the live census, and a window whose process has no
   *  launch time cannot be told from a recreated one, so it is not kept. */
  serialize(): SavedDesktop[] {
    return [...this.entries.values()].flatMap((list) => {
      const windows = windowsOf(list)
        .filter((w) => w.launched > 0)
        .map((w) => ({
          pid: w.pid,
          id: w.id,
          launched: w.launched,
          app: w.app,
          bundleID: w.bundleID,
        }));
      return windows.length ? [{display: list.display, space: list.space, windows}] : [];
    });
  }

  /** Replaces every list with the saved ones that a complete census confirms:
   *  at least one saved window must still exist and still belong to that
   *  Space, since display and Space IDs repeat after a restart. Saved windows
   *  the census no longer has are gone, not waited for, and a Desktop without
   *  an anchor starts fresh through reconciliation. */
  restore(saved: SavedDesktop[], snapshot: Snapshot): {restored: number; dropped: number} {
    this.entries.clear();
    const census = new Map(snapshot.windows.map((w) => [identity(w), w]));
    for (const desktop of saved) {
      const slots: ListedWindow[] = [],
        seen = new Set<string>();
      let anchored = false;
      for (const window of desktop.windows) {
        const key = identity(window),
          live = census.get(key);
        if (!live || seen.has(key)) continue;
        seen.add(key);
        slots.push(listed(live));
        if (live.spaces.includes(desktop.space)) anchored = true;
      }
      if (anchored) {
        this.entries.set(this.key(desktop.display, desktop.space), {...desktop, slots});
      }
    }
    const confirmed = new Set(this.entries.keys());
    this.reconcile(snapshot);
    const restored = saved.filter((d) => {
      const key = this.key(d.display, d.space);
      return confirmed.has(key) && this.entries.has(key);
    }).length;
    return {restored, dropped: saved.length - restored};
  }
}
