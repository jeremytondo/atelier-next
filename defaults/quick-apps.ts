// One toggle per configured app: hide it when it is frontmost with a visible
// window, otherwise summon it to the center of the target display. Launching
// quietly and pinning to every Desktop come from the API; hiding, unhiding,
// placement, and focus use `hs.*`. Summoning keeps launch, placement, pinning,
// and final focus together so it cannot switch Desktops before membership is
// established. The workspace seams let tests drive the whole transaction
// against a fake Mac.
import type {ApplicationAPI, ResolvedApplication} from "../api/application.ts";
import type {HS} from "../api/hs.ts";
import type {Frame, Snapshot, SpacesAPI} from "../api/spaces.ts";
import type {Timers} from "../api/timers.ts";
import {setAXAttribute} from "./accessibility.ts";
import type {QuickAppSize} from "./configuration.ts";

export interface RunningApp {
  pid: number;
  bundleID: string | null;
}

/** The AppKit, Accessibility, and Spaces behavior a toggle drives. Apps are
 *  process IDs and windows are window IDs so fakes need no HS2 objects. */
export interface Workspace {
  now(): number;
  sleep(seconds: number): Promise<void>;
  snapshot(): Promise<Snapshot>;
  /** The first running instance of a bundle identifier. */
  running(bundleID: string): number | null;
  frontmost(): RunningApp | null;
  isRunning(pid: number): boolean;
  isHidden(pid: number): boolean;
  hide(pid: number): boolean;
  unhide(pid: number): void;
  /** Launches or reopens without activating and returns once macOS reports the process. */
  launch(target: ResolvedApplication): Promise<number>;
  /** Standard and dialog windows that are neither modal nor full screen. */
  windows(pid: number): number[];
  isMinimized(window: number): boolean;
  unminimize(window: number): boolean;
  frame(window: number): Frame | null;
  move(window: number, x: number, y: number): boolean;
  resize(window: number, w: number, h: number): boolean;
  /** Makes the window main, activates its app, and raises it. */
  focus(pid: number, window: number): void;
  focusedWindow(): number;
  spaces(window: number): Promise<string[]>;
  /** The display's frame minus the menu bar and Dock, in top-left coordinates. */
  usableFrame(display: string): Frame | null;
  /** Puts the window on every required Desktop and describes how. */
  pin(pid: number, window: number, target: ResolvedApplication, spaces: string[]): Promise<string>;
}

interface State {
  pid: number;
  window: number;
  /** The app to return to when the Quick App hides, unless it was the Quick App itself. */
  previous: RunningApp | null;
  previousWindow: number;
  display: string;
  space: string;
}

export interface ToggleResult {
  action: "hidden" | "shown";
  bundleID: string;
  restoredFocus?: boolean;
  window?: number;
  display?: string;
  space?: string;
  frame?: Frame | null;
  assignment?: string;
}

export const windowTimeout = 4;
const placementAttempts = 20;

export class QuickApps {
  readonly states = new Map<string, State>();
  private readonly ws: Workspace;

  constructor(workspace: Workspace) {
    this.ws = workspace;
  }

  async toggle(target: ResolvedApplication, size?: QuickAppSize): Promise<ToggleResult> {
    const ws = this.ws;
    if (size && ![size.width, size.height].every((v) => Number.isFinite(v) && v > 0))
      throw new Error("Invalid quick app size");
    const running = ws.running(target.bundleID);
    if (
      running !== null &&
      !ws.isHidden(running) &&
      ws.frontmost()?.pid === running &&
      ws.windows(running).some((w) => !ws.isMinimized(w))
    )
      return this.hide(running, target);
    return this.summon(running, target, size);
  }

  /** True as soon as `condition` holds; false once `timeout` seconds elapse without it. */
  private async wait(
    timeout: number,
    condition: () => boolean | Promise<boolean>,
  ): Promise<boolean> {
    const ws = this.ws,
      started = ws.now();
    do {
      if (await condition()) return true;
      await ws.sleep(0.04);
    } while (ws.now() - started < timeout);
    return condition();
  }

  private async currentSpace(display: string): Promise<string | undefined> {
    const snapshot = await this.ws.snapshot();
    return snapshot.displays.find((d) => d.id === display)?.current;
  }

  private async hide(pid: number, target: ResolvedApplication): Promise<ToggleResult> {
    const ws = this.ws,
      bundleID = target.bundleID;
    if (!ws.hide(pid)) throw new Error("Could not hide " + target.name);
    if (!(await this.wait(1, () => ws.isHidden(pid))))
      throw new Error("Could not verify quick app was hidden");
    let restored = false;
    const state = this.states.get(bundleID);
    const previous = state?.previous;
    if (
      state &&
      state.pid === pid &&
      previous &&
      ws.isRunning(previous.pid) &&
      (await this.currentSpace(state.display)) === state.space &&
      (await ws.spaces(state.previousWindow)).includes(state.space) &&
      ws.windows(previous.pid).includes(state.previousWindow) &&
      !ws.isMinimized(state.previousWindow)
    ) {
      ws.focus(previous.pid, state.previousWindow);
      restored = await this.wait(1, () => ws.focusedWindow() === state.previousWindow);
    }
    if (state) state.previous = null;
    return {action: "hidden", bundleID, restoredFocus: restored};
  }

  private async summon(
    running: number | null,
    target: ResolvedApplication,
    size?: QuickAppSize,
  ): Promise<ToggleResult> {
    const ws = this.ws,
      bundleID = target.bundleID;
    const snapshot = await ws.snapshot();
    const display = snapshot.displays.find((d) => d.id === snapshot.targetDisplay);
    if (!display?.spaces.some((s) => s.id === display.current && !s.fullscreen))
      throw new Error(
        "Quick apps require an ordinary Desktop; fullscreen and Split View are unsupported",
      );
    const space = display.current;
    const frontmost = ws.frontmost();
    const remembered = this.states.get(bundleID);
    // A repeated press while the Quick App is already frontmost keeps the app
    // the user came from, so hiding later still returns there.
    const reusePrevious =
      frontmost?.bundleID === bundleID &&
      remembered?.display === display.id &&
      remembered?.space === space;
    const previous = reusePrevious ? (remembered?.previous ?? null) : frontmost;
    const previousWindow = reusePrevious ? (remembered?.previousWindow ?? 0) : ws.focusedWindow();
    const checkDesktop = async () => {
      if ((await this.currentSpace(display.id)) !== space)
        throw new Error("Active Desktop changed during quick app summon");
    };

    const pid = running !== null && ws.windows(running).length ? running : await ws.launch(target);
    let selected: number | undefined;
    await this.wait(windowTimeout, () => {
      const windows = ws.windows(pid),
        focused = ws.focusedWindow();
      selected =
        windows.find((w) => remembered?.pid === pid && w === remembered.window) ??
        windows.find((w) => w === focused) ??
        windows[0];
      return selected !== undefined;
    });
    if (selected === undefined)
      throw new Error(
        target.name +
          " did not expose a standard window; close fullscreen mode or open its main window",
      );
    const window = selected;
    await checkDesktop();
    // Hidden apps may have no queryable Space membership. Unhide without activating
    // before pinning; only focus after membership on the captured Desktop is verified.
    ws.unhide(pid);
    if (ws.isMinimized(window) && !ws.unminimize(window))
      throw new Error("Quick app window could not be unminimized");
    await this.place(window, display.id, size);
    await checkDesktop();
    const expected = display.spaces.filter((s) => !s.fullscreen).map((s) => s.id);
    const assignment = await ws.pin(pid, window, target, expected);
    await checkDesktop();
    // Keep this identity even if a later step fails, allowing a second press to hide.
    this.states.set(bundleID, {
      pid,
      window,
      previous: previous?.bundleID === bundleID ? null : previous,
      previousWindow,
      display: display.id,
      space,
    });
    if (
      !(await this.wait(1, async () => {
        const spaces = await ws.spaces(window);
        return expected.every((id) => spaces.includes(id));
      }))
    )
      throw new Error("Quick app is not available on every Desktop of the captured display");
    ws.focus(pid, window);
    const focused = await this.wait(1.5, () => ws.focusedWindow() === window);
    await checkDesktop();
    if (!focused) throw new Error("Could not focus the quick app window");
    return {
      action: "shown",
      bundleID,
      window,
      display: display.id,
      space,
      frame: ws.frame(window),
      assignment,
    };
  }

  /** Centers the window in the display's usable area, shrinking it to fit. */
  private async place(window: number, display: string, size?: QuickAppSize): Promise<void> {
    const ws = this.ws;
    const visible = ws.usableFrame(display);
    if (!visible) throw new Error("Quick app display disconnected");
    const usable = {x: visible.x + 8, y: visible.y + 8, w: visible.w - 16, h: visible.h - 16};
    const old = ws.frame(window);
    if (!old) throw new Error("Quick app window has no readable frame");
    const center = (w: number, h: number) => ({
      x: usable.x + usable.w / 2 - w / 2,
      y: usable.y + usable.h / 2 - h / 2,
    });
    // Move without activation so the window reaches the captured display first.
    const first = center(Math.min(old.w, usable.w), Math.min(old.h, usable.h));
    if (!ws.move(window, first.x, first.y)) throw new Error("Quick app refused window placement");
    if (size || old.w > usable.w || old.h > usable.h) {
      const w = Math.min(size?.width ?? old.w, usable.w),
        h = Math.min(size?.height ?? old.h, usable.h);
      if (!ws.resize(window, w, h)) throw new Error("Quick app refused the requested size");
    }
    // Recenter using the actual size: apps may impose their own minimum dimensions.
    for (let attempt = 0; attempt < placementAttempts; attempt++) {
      await ws.sleep(0.04);
      const actual = ws.frame(window);
      if (!actual) continue;
      const point = center(actual.w, actual.h);
      if (!ws.move(window, point.x, point.y)) throw new Error("Quick app refused window placement");
      await ws.sleep(0.04);
      const settled = ws.frame(window);
      if (
        settled &&
        Math.abs(settled.x - point.x) < 3 &&
        Math.abs(settled.y - point.y) < 3 &&
        Math.abs(settled.w - actual.w) < 3 &&
        Math.abs(settled.h - actual.h) < 3
      )
        return;
    }
    throw new Error("Quick app did not settle at the center of the captured display");
  }
}

/** The live macOS behavior behind QuickApps, over `hs.*` and the API. */
export function liveWorkspace(
  hs: HS,
  api: {spaces: SpacesAPI; application: ApplicationAPI},
  timers: Timers,
): Workspace {
  // Window IDs handed out by the most recent enumeration, so later reads and
  // writes need no lookup.
  const byID = new Map<number, HSWindow>();
  const app = (pid: number) => hs.application.fromPID(pid);
  const plain = (frame: HSRect | null): Frame | null =>
    frame && {x: frame.x, y: frame.y, w: frame.w, h: frame.h};
  return {
    now: () => Date.now() / 1000,
    sleep: (seconds) => timers.sleep(seconds),
    snapshot: () => api.spaces.snapshot(),
    running: (bundleID) => hs.application.matchingBundleID(bundleID)?.pid ?? null,
    frontmost: () => {
      const front = hs.application.frontmost();
      return front && {pid: front.pid, bundleID: front.bundleID};
    },
    isRunning: (pid) => app(pid)?.isRunning ?? false,
    isHidden: (pid) => app(pid)?.isHidden ?? true,
    hide: (pid) => {
      const target = app(pid);
      if (!target) return false;
      target.hide();
      return true;
    },
    unhide: (pid) => app(pid)?.unhide(),
    launch: async (target) => (await api.application.launch(target.path)).pid,
    windows: (pid) => {
      byID.clear();
      const ids: number[] = [];
      for (const window of app(pid)?.allWindows ?? []) {
        const element = window.axElement();
        if (
          window.id <= 0 ||
          !["AXStandardWindow", "AXDialog"].includes(element.subrole ?? "") ||
          element.attributeValue("AXModal") === true ||
          window.isFullscreen
        )
          continue;
        byID.set(window.id, window);
        ids.push(window.id);
      }
      return ids;
    },
    isMinimized: (id) => byID.get(id)?.isMinimized === true,
    unminimize: (id) => byID.get(id)?.unminimize() === true,
    frame: (id) => plain(byID.get(id)?.frame ?? null),
    move: (id, x, y) => {
      const window = byID.get(id);
      if (!window) return false;
      window.position = new HSPoint(x, y);
      return true;
    },
    resize: (id, w, h) => {
      const window = byID.get(id);
      if (!window) return false;
      window.size = new HSSize(w, h);
      return true;
    },
    focus: (pid, id) => {
      const window = byID.get(id);
      if (!window) return;
      setAXAttribute(window.axElement(), "AXMain", true);
      app(pid)?.activate(false);
      window.focus();
      window.raise();
    },
    focusedWindow: () => hs.window.focusedWindow()?.id ?? 0,
    spaces: async (id) => (await api.spaces.membership(id)).spaces,
    usableFrame: (display) => {
      const screen =
        display === "Main"
          ? hs.screen.primary()
          : hs.screen.all().find((s) => s.uuid.toUpperCase() === display.toUpperCase());
      return plain(screen?.frame ?? null);
    },
    pin: async (pid, window, target, spaces) =>
      (await api.spaces.pin({pid, window, app: target.path, spaces})).assignment,
  };
}
