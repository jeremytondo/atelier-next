// One display with an editor window in front. Launching the Quick App gives it
// process 20 and window 200 on the current Desktop. Time advances with sleeps.
import type {ResolvedApplication} from "../api/application.ts";
import type {DisplayInfo, Frame, Snapshot} from "../api/spaces.ts";
import type {Workspace} from "../defaults/quick-apps.ts";

export const desktop = (id: string, fullscreen = false) => ({id, fullscreen});
export const display = (
  spaces: {id: string; fullscreen: boolean}[],
  current: string,
): DisplayInfo => ({
  id: "A",
  current,
  spaces,
});
export const quick: ResolvedApplication = {
  bundleID: "com.example.quick",
  name: "Quick",
  path: "/Applications/Quick.app",
};

interface App {
  bundleID: string;
  hidden: boolean;
  windows: number[];
}

interface Win {
  frame: Frame;
  minimized: boolean;
  spaces: string[];
}

export class FakeWorkspace implements Workspace {
  time = 0;
  topology = [display([desktop("1"), desktop("2")], "1")];
  apps = new Map<number, App>([
    [10, {bundleID: "com.example.editor", hidden: false, windows: [100]}],
  ]);
  wins = new Map<number, Win>([
    [100, {frame: {x: 50, y: 50, w: 800, h: 600}, minimized: false, spaces: ["1"]}],
  ]);
  front: number | null = 10;
  focused = 100;
  visible: Frame = {x: 0, y: 25, w: 1440, h: 875};
  launches: string[] = [];
  /** The launched app's first window, or null for an app that shows none. */
  launchedWindowFrame: Frame | null = {x: 0, y: 0, w: 2000, h: 1200};
  changeDesktopAfterLaunch = false;
  pins: {pid: number; window: number; required: string[]}[] = [];
  pinSpreads = true;
  pinFails = false;
  focusWorks = true;
  hideRefused = false;
  hideIgnored = false;
  minimumSize: {w: number; h: number} | null = null;

  get current(): string {
    return this.topology[0]!.current;
  }
  now(): number {
    return this.time;
  }
  async sleep(): Promise<void> {
    this.time += 0.04;
  }
  async snapshot(): Promise<Snapshot> {
    return {
      trusted: true,
      focused: this.focused,
      targetDisplay: "A",
      missionControl: false,
      displays: JSON.parse(JSON.stringify(this.topology)),
      windows: [],
    };
  }
  running(bundleID: string): number | null {
    for (const [pid, app] of this.apps) if (app.bundleID === bundleID) return pid;
    return null;
  }
  frontmost() {
    return this.front === null
      ? null
      : {pid: this.front, bundleID: this.apps.get(this.front)?.bundleID ?? null};
  }
  isRunning(pid: number): boolean {
    return this.apps.has(pid);
  }
  isHidden(pid: number): boolean {
    return this.apps.get(pid)?.hidden ?? true;
  }
  hide(pid: number): boolean {
    if (this.hideRefused) return false;
    if (this.hideIgnored) return true;
    const app = this.apps.get(pid);
    if (app) app.hidden = true;
    if (this.front === pid) {
      this.front = null;
      this.focused = 0;
    }
    return true;
  }
  unhide(pid: number): void {
    const app = this.apps.get(pid);
    if (app) app.hidden = false;
  }
  async launch(target: ResolvedApplication): Promise<number> {
    this.launches.push(target.bundleID);
    const app: App = {bundleID: target.bundleID, hidden: false, windows: []};
    if (this.launchedWindowFrame) {
      app.windows = [200];
      this.wins.set(200, {
        frame: {...this.launchedWindowFrame},
        minimized: false,
        spaces: [this.current],
      });
    }
    this.apps.set(20, app);
    if (this.changeDesktopAfterLaunch) this.topology = [display([desktop("1"), desktop("2")], "2")];
    return 20;
  }
  windows(pid: number): number[] {
    return this.apps.get(pid)?.windows ?? [];
  }
  isMinimized(id: number): boolean {
    return this.wins.get(id)?.minimized ?? false;
  }
  unminimize(id: number): boolean {
    const win = this.wins.get(id);
    if (win) win.minimized = false;
    return true;
  }
  frame(id: number): Frame | null {
    const win = this.wins.get(id);
    return win ? {...win.frame} : null;
  }
  move(id: number, x: number, y: number): boolean {
    const win = this.wins.get(id);
    if (!win) return false;
    win.frame.x = x;
    win.frame.y = y;
    return true;
  }
  resize(id: number, w: number, h: number): boolean {
    const win = this.wins.get(id);
    if (!win) return false;
    win.frame.w = this.minimumSize ? Math.max(w, this.minimumSize.w) : w;
    win.frame.h = this.minimumSize ? Math.max(h, this.minimumSize.h) : h;
    return true;
  }
  focus(pid: number, id: number): void {
    if (!this.focusWorks) return;
    this.front = pid;
    this.focused = id;
  }
  focusedWindow(): number {
    return this.focused;
  }
  async spaces(id: number): Promise<string[]> {
    return [...(this.wins.get(id)?.spaces ?? [])];
  }
  usableFrame(): Frame | null {
    return {...this.visible};
  }
  async pin(
    pid: number,
    window: number,
    _: ResolvedApplication,
    required: string[],
  ): Promise<string> {
    this.pins.push({pid, window, required});
    if (this.pinFails) throw new Error("Dock automation failed: expected");
    const win = this.wins.get(window);
    if (this.pinSpreads && win) win.spaces = [...required].sort();
    return "assigned";
  }
}
