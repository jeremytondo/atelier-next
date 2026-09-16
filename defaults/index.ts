// The Atelier defaults: per-Desktop window lists, Desktop shortcuts, Quick
// Apps, and the overlay, as policy over `hs.*` and the API. One session owns
// every binding, observer, timer, and the providers process; stopping releases
// all of them and leaves independent HS2 scripts untouched.
import type {ResolvedApplication} from "../api/application.ts";
import type {HS} from "../api/hs.ts";
import type {AtelierAPI} from "../api/index.ts";
import type {Snapshot} from "../api/spaces.ts";
import {Timers} from "../api/timers.ts";
import {setAXAttribute} from "./accessibility.ts";
import {
  type Config,
  defaults as defaultOptions,
  normalize,
  type Options,
  type PresetEntry,
  type QuickAppEntry,
  type Shortcut,
  shortcut,
} from "./configuration.ts";
import {Overlay} from "./overlay.ts";
import {liveWorkspace, QuickApps, type ToggleResult, type Workspace} from "./quick-apps.ts";
import {Startup} from "./startup.ts";
import {StateFile} from "./state.ts";
import {
  type DesktopWindows,
  identity,
  isWindow,
  type ListedWindow,
  type MoveTarget,
  moveTarget,
  type WaitingSlot,
  WindowLists,
  windowsOf,
} from "./windows.ts";

export interface DefaultsInfo {
  /** The Hammerspoon 2 build number Atelier was tested against. */
  expectedBuild: string;
  version: string;
  /** Replaces the live workspace; tests inject a fake Mac. */
  workspace?: (timers: Timers) => Workspace;
}

export type State = "Paused" | "Starting" | "Waiting for Accessibility" | "Running" | "Stopped";
export type SpaceAction = "switch" | "create" | "reorder" | "delete";
export type Busy = {busy: true};
export type Noop = {noop: true};
export type WindowResult = {window: number} | Noop | Busy;

/** The apps whose preset slot was left empty. */
export interface AppliedPreset {
  skipped: string[];
}

/** Operations on the focused Desktop's window list. */
export interface WindowCommands {
  /** Reveals and focuses the window at the one-based slot. */
  select(slot: number): Promise<WindowResult>;
  /** Focuses the window `offset` places from the focused one, wrapping at either end. */
  cycle(offset: number): Promise<WindowResult>;
  /** Moves the focused window by an offset or to a final slot, without touching focus or geometry. */
  move(target: MoveTarget): Promise<WindowResult>;
}

export interface Status {
  state: State;
  error: string | null;
  version: string;
  hammerspoon2: {build: string; expectedBuild: string};
  quickApps: {app: string; bundleID: string; shortcut: string}[];
  /** Each preset with the apps that resolved at start-up. */
  presets: {name: string; apps: string[]; shortcut: string | null}[];
  /** Desktops with a list, and the state file with its last write and start-up restore result. */
  windows: {
    lists: number;
    file: {path: string; savedAt: string | null; restored: number | null; dropped: number | null};
  };
  metrics: {name: string; milliseconds: number}[];
}

export interface Defaults {
  /** Starts the defaults; a later call without options resumes with the previous ones. */
  start(options?: Options): Promise<Defaults>;
  /** Stops automation and pending startup, releasing owned resources. */
  stop(): void;
  status(): Status;
  /** A fresh copy of the shipped options. */
  defaults(): Required<Options>;
  windows: WindowCommands;
  /** Launches a preset's apps on an empty Desktop and numbers them in the declared order. */
  preset(name: string): Promise<AppliedPreset | Busy>;
  space(
    command: SpaceAction,
    args?: {number?: number; offset?: -1 | 1},
  ): Promise<Snapshot | Noop | Busy>;
  quickApp(app: string): Promise<ToggleResult | Busy>;
}

type QuickApp = QuickAppEntry & ResolvedApplication;
interface Preset extends PresetEntry {
  resolved: ResolvedApplication[];
}

/** How long a preset's slot waits for its app to show a window on the Desktop. */
export const waitingSeconds = 30;
/** Focus is verified this many times, 5 ms apart, before a selection is reported failed. */
const focusAttempts = 300;
/** How often the lists follow the census between commands and window events. */
const pollSeconds = 2;

const events = [
  "AXFocusedWindowChanged",
  "AXWindowCreated",
  "AXUIElementDestroyed",
  "AXWindowMiniaturized",
  "AXWindowDeminiaturized",
  "AXApplicationHidden",
  "AXApplicationShown",
];
const spaceActions: SpaceAction[] = ["switch", "create", "reorder", "delete"];

/** Whether Accessibility calls this an ordinary window rather than a dialog,
 *  panel, or sheet; the same test the providers apply to the census. */
function ordinary(element: HSAXElement | null | undefined): boolean {
  return !!element && element.role === "AXWindow" && element.isAttributeSettable("AXMinimized");
}

export function createDefaults(hs: HS, api: AtelierAPI, info: DefaultsInfo): Defaults {
  const lists = new WindowLists(),
    file = new StateFile(hs),
    timers = new Timers(hs),
    startup = new Startup(hs);
  const bindings: {key: HSHotkey; space: boolean}[] = [],
    observers = new Map<number, {element: HSAXElement; callback: () => void}>(),
    metrics: Status["metrics"] = [];
  let notificationsRequested = false;
  let config: Config = normalize(),
    generation = 0,
    busy = false,
    observing = false,
    snapshot: Snapshot | null = null;
  let state: State = "Paused",
    lastError: string | null = null,
    poll: HSTimer | null = null,
    overlay: Overlay | null = null,
    workspace: Workspace | null = null,
    quick: QuickApps | null = null,
    quickApps: QuickApp[] = [],
    presets: Preset[] = [],
    chooser: HSChooser | null = null,
    startOptions: Options | undefined,
    unwatchFailures: (() => void) | null = null,
    // Saving starts after restore so start-up cannot overwrite the file with nothing.
    persisting = false,
    restored: {restored: number; dropped: number} | null = null;
  const valid = (epoch: number) =>
    generation === epoch && ["Starting", "Waiting for Accessibility", "Running"].includes(state);
  function assertValid(epoch: number) {
    if (!valid(epoch)) throw new Error("Atelier session changed");
  }
  function record(name: string, began: number) {
    metrics.push({name, milliseconds: Date.now() - began});
    if (metrics.length > 100) metrics.shift();
  }
  function notify(message: string) {
    // Notifications are optional; the HS2 Console always retains the line.
    try {
      hs.notify.show("Atelier", message, () => hs.openConsole());
    } catch (_) {
      /* notifications may be denied */
    }
  }
  function report(error: unknown) {
    lastError = String(error instanceof Error ? error.message : error);
    console.error("Atelier: " + lastError);
    notify(lastError);
  }
  function fire(promise: Promise<unknown>) {
    promise.catch(() => {});
  }
  // The window has focus, or, once it was asked forward, macOS keeps focus on
  // a dialog or sheet of its app; that modal behavior is respected, not bypassed.
  function focusedOn(window: ListedWindow, raised: boolean) {
    const focused = hs.window.focusedWindow();
    if (!focused || focused.pid !== window.pid) return false;
    return focused.id === window.id || (raised && !ordinary(focused.axElement()));
  }
  function find(window: ListedWindow) {
    const app = hs.application.fromPID(window.pid);
    return app?.allWindows.find((w) => w.id === window.id && w.pid === window.pid);
  }
  function redraw() {
    if (overlay && snapshot) overlay.update(snapshot, lists.focused(snapshot));
  }
  function persist() {
    if (persisting) file.save(lists.serialize());
  }
  // Runs once per session, on the first complete census: an incomplete one
  // could not tell a closed window from an unseen one.
  function restore(first: Snapshot) {
    const read = file.read();
    if (read.status === "ok") {
      restored = lists.restore(read.desktops, first);
      console.log(
        "Atelier: Restored " + restored.restored + " window lists, dropped " + restored.dropped,
      );
    } else {
      lists.entries.clear();
      lists.reconcile(first);
      if (read.status === "missing") console.log("Atelier: No saved window lists at " + file.path);
      else console.log("Atelier: Ignoring " + read.status + " window lists at " + file.path);
    }
    persisting = true;
  }
  async function refresh(epoch: number) {
    const next = await api.spaces.snapshot();
    assertValid(epoch);
    if (!next.trusted) throw new Error(accessibilityMessage);
    const excluded = new Set(quickApps.map((app) => app.bundleID));
    next.windows = next.windows.filter(
      (w) => w.bundleID !== hs.appinfo.bundleIdentifier && !excluded.has(w.bundleID),
    );
    snapshot = next;
    // An incomplete census proves nothing; the lists wait for the next one.
    if (config.windows && next.complete) {
      if (persisting) lists.reconcile(next);
      else restore(next);
    }
    persist();
    syncObservers();
    redraw();
    return next;
  }
  // Watches the processes with a listed window; nothing otherwise.
  function syncObservers() {
    const pids = new Set<number>();
    for (const list of lists.entries.values()) for (const w of windowsOf(list)) pids.add(w.pid);
    for (const [pid, entry] of observers) {
      if (pids.has(pid)) continue;
      hs.ax.removeWatcher(entry.element, events, entry.callback);
      observers.delete(pid);
    }
    for (const pid of pids) {
      if (observers.has(pid)) continue;
      const app = hs.application.fromPID(pid);
      if (!app) continue;
      // HS2 watches AX elements, including application elements; retain the
      // same element and callback for symmetric removal.
      const element = hs.ax.applicationElement(app);
      if (!element) continue;
      const callback = () => {
        redraw();
        observe();
      };
      observers.set(pid, {element, callback});
      hs.ax.addWatcher(element, events, callback);
    }
  }
  async function run<Result>(
    name: string,
    action: (epoch: number) => Promise<Result>,
  ): Promise<Result | Busy> {
    if (state !== "Running")
      throw new Error("Atelier defaults are stopped; call atelier.start() or Reload Config");
    if (busy) return {busy: true};
    busy = true;
    const epoch = generation,
      began = Date.now();
    try {
      return await action(epoch);
    } catch (error) {
      if (valid(epoch)) report(error);
      throw error;
    } finally {
      if (generation === epoch) busy = false;
      record(name, began);
    }
  }
  /** Reveals the window if hidden or minimized, brings it forward, and verifies focus. */
  async function focus(window: ListedWindow, epoch: number): Promise<void> {
    const target = find(window);
    if (!target) throw new Error("The selected window closed");
    if (focusedOn(window, false)) return;
    const application = target.application;
    if (application?.isHidden) application.unhide();
    if (target.isMinimized) target.unminimize();
    setAXAttribute(application?.axElement(), "AXFrontmost", true);
    setAXAttribute(target.axElement(), "AXMain", true);
    target.axElement().performAction("AXRaise");
    for (let attempt = 0; attempt < focusAttempts && !focusedOn(window, true); attempt++) {
      await timers.sleep(0.005);
      assertValid(epoch);
    }
    if (!focusedOn(window, true)) throw new Error("Could not focus the window in " + window.app);
    redraw();
  }
  function observe() {
    if (state !== "Running" || busy || observing) return;
    observing = true;
    const epoch = generation;
    refresh(epoch)
      .catch((error) => {
        if (valid(epoch)) report(error);
      })
      .finally(() => {
        if (generation === epoch) observing = false;
      });
  }
  const select = (slot: number) =>
    run("select", async (epoch): Promise<{window: number} | Noop> => {
      const next = await refresh(epoch),
        window = lists.focused(next)?.slots[slot - 1];
      if (!window || !isWindow(window)) return {noop: true};
      await focus(window, epoch);
      return {window: window.id};
    });
  const cycle = (offset: number) =>
    run("cycle", async (epoch): Promise<{window: number} | Noop> => {
      const next = await refresh(epoch),
        list = lists.focused(next),
        windows = list ? windowsOf(list) : [],
        count = windows.length;
      if (!count) return {noop: true};
      // With nothing listed focused, next starts at the first window and previous at the last.
      const current = windows.findIndex((w) => w.id === next.focused),
        from = current >= 0 ? current : offset > 0 ? -1 : count;
      const window = windows[(((from + offset) % count) + count) % count];
      if (!window) return {noop: true};
      await focus(window, epoch);
      return {window: window.id};
    });
  const move = (target: MoveTarget) =>
    run("move", async (epoch): Promise<{window: number} | Noop> => {
      const request = moveTarget(target);
      const next = await refresh(epoch),
        list = lists.focused(next),
        window = list && windowsOf(list).find((w) => w.id === next.focused);
      if (!list || !window || !lists.move(list, window, request)) return {noop: true};
      persist();
      redraw();
      return {window: window.id};
    });
  // Gives up a preset's waiting slots; a list replaced meanwhile is left alone.
  function expire(list: DesktopWindows) {
    if (lists.entries.get(lists.key(list.display, list.space)) !== list) return;
    const names = lists.expire(list);
    if (names.length) console.log("Atelier: Gave up waiting for " + names.join(", "));
    persist();
    redraw();
  }
  const preset = (name: string) =>
    run("preset", async (epoch): Promise<AppliedPreset> => {
      const entry = presets.find((p) => p.name === name),
        ws = workspace;
      if (!entry || !ws) throw new Error("Preset is not configured: " + name);
      if (!config.windows) throw new Error("Presets need window lists; set windows: true");
      if (!entry.resolved.length) throw new Error("No app in preset " + name + " is installed");
      const next = await refresh(epoch);
      if (!next.complete) throw new Error("Could not read the windows; try again");
      const list = lists.prepare(next),
        named: WaitingSlot[] = [],
        skipped: string[] = [],
        revealed = new Set<string>();
      // The census decides which windows count and where they are; the workspace
      // only reveals them. Unknown membership is not membership here.
      const listedAnywhere = new Set<string>();
      for (const each of lists.entries.values())
        for (const w of windowsOf(each)) listedAnywhere.add(identity(w));
      const ordinaryWindows = (pid: number) =>
        next.windows.filter(
          (w) => w.pid === pid && (w.ordinary === true || listedAnywhere.has(identity(w))),
        );
      try {
        for (const app of entry.resolved) {
          const pid = ws.running(app.bundleID),
            windows = pid === null ? [] : ordinaryWindows(pid);
          if (pid !== null && windows.length) {
            const here = ws
              .windows(pid)
              .filter((id) => windows.some((w) => w.id === id && w.spaces.includes(list.space)));
            if (!here.length) {
              skipped.push(app.name);
              console.log("Atelier: " + app.name + " is open on another Desktop; slot left empty");
              continue;
            }
            // Reveal without activating; the window then arrives through the census.
            if (ws.isHidden(pid)) ws.unhide(pid);
            for (const window of here) if (ws.isMinimized(window)) ws.unminimize(window);
            revealed.add(app.bundleID);
          } else {
            try {
              await ws.launch(app);
              assertValid(epoch);
            } catch (error) {
              assertValid(epoch);
              skipped.push(app.name);
              console.log("Atelier: Could not launch " + app.name + ": " + String(error));
              continue;
            }
          }
          named.push({bundleID: app.bundleID, app: app.name});
        }
      } finally {
        if (valid(epoch)) {
          lists.seed(list, named);
          // Whatever happened, slots still waiting must not wait forever.
          if (list.slots.some((slot) => !isWindow(slot)))
            timers.after(waitingSeconds, () => expire(list));
        }
      }
      // Windows that were only hidden or minimized are on the Desktop already.
      await refresh(epoch);
      // Only a window that was already here takes focus; a launched one never does.
      const first = list.slots[0];
      if (first && isWindow(first) && revealed.has(first.bundleID)) await focus(first, epoch);
      return {skipped};
    });
  const space = (command: SpaceAction, args: {number?: number; offset?: -1 | 1} = {}) =>
    run(command, async (epoch): Promise<Snapshot | Noop> => {
      if (!spaceActions.includes(command)) throw new Error("Unknown Space action");
      const next = await refresh(epoch),
        display = next.displays.find((d) => d.id === next.targetDisplay);
      if (!display) throw new Error("No target display");
      const spaceKeys = bindings.filter((b) => b.space);
      for (const {key} of spaceKeys) key.disable();
      try {
        const target = {display: display.id, current: display.current};
        let result: Snapshot | Noop;
        if (command === "switch") {
          if (args.number === undefined) throw new Error("number required");
          result = await api.spaces.switch({...target, number: args.number});
        } else if (command === "reorder") {
          if (args.offset === undefined) throw new Error("offset required");
          result = await api.spaces.reorder({...target, offset: args.offset});
        } else if (command === "create") {
          result = await api.spaces.create(target);
        } else {
          result = await api.spaces.delete(target);
        }
        await refresh(epoch);
        return result;
      } finally {
        if (valid(epoch)) {
          for (const {key} of spaceKeys) {
            if (key.enable()) continue;
            session.stop();
            report(new Error("Could not restore Desktop shortcuts; call atelier.start()"));
            break;
          }
        }
      }
    });
  const quickApp = (app: string) =>
    run("quickApp", async (epoch) => {
      const entry = quickApps.find((e) => e.app === app || e.bundleID === app);
      if (!entry || !quick) throw new Error("Quick App is not configured: " + app);
      const result = await quick.toggle(entry, entry.size);
      await refresh(epoch);
      return result;
    });
  const status = (): Status => ({
    state,
    error: lastError,
    version: info.version,
    hammerspoon2: {build: hs.appinfo.build, expectedBuild: info.expectedBuild},
    quickApps: quickApps.map((a) => ({app: a.app, bundleID: a.bundleID, shortcut: a.shortcut})),
    presets: presets.map((p) => ({
      name: p.name,
      apps: p.resolved.map((a) => a.name),
      shortcut: p.shortcut?.text ?? null,
    })),
    windows: {
      lists: lists.entries.size,
      file: {
        path: file.path,
        savedAt: file.savedAt,
        restored: restored?.restored ?? null,
        dropped: restored?.dropped ?? null,
      },
    },
    metrics,
  });
  function bind(binding: Shortcut, action: () => Promise<unknown>, space = false) {
    const occupied = hs.hotkey.getHotkeys().some((key) => {
      try {
        return shortcut(key.mods.join("-") + "-" + key.key).identity === binding.identity;
      } catch (_) {
        return false;
      }
    });
    if (occupied || !hs.hotkey.assignable(binding.mods, binding.key))
      throw new Error("Shortcut unavailable: " + binding.identity);
    const key = hs.hotkey.create(
      binding.mods,
      binding.key,
      () => fire(Promise.resolve().then(action)),
      null,
      null,
    );
    if (!key?.enable()) {
      if (key) key.destroy();
      throw new Error("Shortcut unavailable: " + binding.identity);
    }
    bindings.push({key, space});
  }
  const actions: Record<string, () => Promise<unknown>> = {
    presets: async () => {
      if (!chooser) return;
      chooser.query = "";
      chooser.show();
    },
    "cycle-previous": () => cycle(-1),
    "cycle-next": () => cycle(1),
    "move-previous": () => move(-1),
    "move-next": () => move(1),
    // Stop first so pending list state reaches disk before the context goes.
    "reload-config": async () => {
      session.stop();
      hs.reload();
    },
    "desktop-create": () => space("create"),
    "desktop-left": () => space("reorder", {offset: -1}),
    "desktop-right": () => space("reorder", {offset: 1}),
    "desktop-delete": () => space("delete"),
  };
  for (let n = 1; n <= 10; n++) {
    actions["desktop-" + n] = () => space("switch", {number: n});
    actions["select-" + n] = () => select(n);
    actions["move-" + n] = () => move({slot: n});
  }
  function checkBuild() {
    const build = hs.appinfo.build;
    if (build === info.expectedBuild) return;
    const message =
      "Hammerspoon 2 build " +
      build +
      " is not the tested build " +
      info.expectedBuild +
      "; Atelier defaults may misbehave until Hammerspoon 2 matches the pin";
    console.log("Atelier: " + message);
    notify(message);
  }
  function requestNotifications() {
    // hs.notify.show does not request permission itself; ask once per context.
    if (notificationsRequested) return;
    notificationsRequested = true;
    try {
      const request = hs.permissions.requestNotifications();
      if (request && typeof request.catch === "function") request.catch(() => {});
    } catch (_) {
      /* the module may be unavailable while permissions are being set up */
    }
  }
  async function waitForAccessibility(epoch: number, provider: boolean) {
    assertValid(epoch);
    state = "Waiting for Accessibility";
    console.log("Atelier: Waiting for Accessibility");
    startup.permission();
    let trusted = false;
    while (!trusted) {
      await timers.sleep(2);
      assertValid(epoch);
      trusted = hs.permissions.checkAccessibility();
      if (trusted && provider) trusted = (await api.spaces.snapshot()).trusted;
      assertValid(epoch);
    }
    state = "Starting";
    startup.close();
  }
  let ready: Promise<Defaults> | null = null;
  const session: Defaults = {
    start(options) {
      if (["Running", "Starting", "Waiting for Accessibility"].includes(state))
        return ready ?? Promise.resolve(session);
      if (options !== undefined) startOptions = options;
      const epoch = ++generation;
      lastError = null;
      state = "Starting";
      ready = (async () => {
        config = normalize(startOptions);
        checkBuild();
        if (!hs.permissions.checkAccessibility()) await waitForAccessibility(epoch, false);
        assertValid(epoch);
        unwatchFailures = api.providers.onFailure((error) => {
          if (generation !== epoch) return;
          session.stop();
          state = "Stopped";
          report(error);
        });
        const hello = await api.providers.start();
        assertValid(epoch);
        if (!hello.trusted) await waitForAccessibility(epoch, true);
        workspace = (info.workspace ?? ((t) => liveWorkspace(hs, api, t)))(timers);
        quick = new QuickApps(workspace);
        quickApps = [];
        const seen = new Set<string>();
        for (const entry of config.quickApps) {
          try {
            const resolved = await api.application.resolve(entry.app);
            assertValid(epoch);
            if (seen.has(resolved.bundleID)) throw new Error("Duplicate Quick App: " + entry.app);
            seen.add(resolved.bundleID);
            quickApps.push({...entry, ...resolved});
          } catch (error) {
            assertValid(epoch);
            report(error);
          }
        }
        presets = [];
        for (const entry of config.presets) {
          // A missing app costs its slot, not the preset; an app listed twice under
          // different names, or shared with a Quick App, is a configuration error.
          const resolved: ResolvedApplication[] = [],
            label = 'Preset "' + entry.name + '"';
          for (const app of entry.apps) {
            let target: ResolvedApplication;
            try {
              target = await api.application.resolve(app);
            } catch (error) {
              assertValid(epoch);
              const message = error instanceof Error ? error.message : String(error);
              report(new Error(label + ": " + message));
              continue;
            }
            assertValid(epoch);
            if (resolved.some((r) => r.bundleID === target.bundleID))
              throw new Error(label + " lists " + app + " twice");
            if (seen.has(target.bundleID)) throw new Error(label + " lists the Quick App " + app);
            resolved.push(target);
          }
          presets.push({...entry, resolved});
        }
        await refresh(epoch);
        for (const binding of config.shortcuts) {
          const action = actions[binding.name];
          if (!action) throw new Error("Unknown binding: " + binding.name);
          if (binding.name === "presets" && !presets.length) continue;
          bind(binding, action, binding.space);
        }
        for (const entry of quickApps) bind(entry, () => quickApp(entry.bundleID));
        if (config.windows) {
          for (const entry of presets)
            if (entry.shortcut) bind(entry.shortcut, () => preset(entry.name));
          if (presets.length) {
            chooser = hs.chooser.create();
            chooser.placeholder = "Preset";
            chooser.setChoices(
              presets.map((p) => ({
                text: p.name,
                subText: p.resolved.map((a) => a.name).join(", "),
              })),
            );
            chooser.onSelect = (item) => {
              if (item && typeof item.text === "string") fire(preset(item.text));
            };
          }
        }
        if (config.windows && config.overlay) {
          overlay = new Overlay(hs, config.overlayFlags, () => {
            redraw();
            observe();
          });
          overlay.start();
        }
        state = "Running";
        console.log("Atelier: Running");
        requestNotifications();
        if (config.windows) poll = hs.timer.doEvery(pollSeconds, observe);
        return session;
      })().catch((error) => {
        if (generation === epoch) {
          session.stop();
          state = "Stopped";
          report(error);
        }
        throw error;
      });
      return ready;
    },
    stop() {
      generation++;
      state = "Paused";
      persist();
      file.flush();
      persisting = false;
      // The file is the truth for the next start; nothing in memory outlives it.
      lists.entries.clear();
      restored = null;
      busy = observing = false;
      if (poll) poll.stop();
      poll = null;
      if (overlay) overlay.stop();
      overlay = null;
      if (chooser) {
        chooser.onSelect = null;
        if (chooser.isVisible) chooser.hide();
      }
      chooser = null;
      quick = null;
      workspace = null;
      for (const {key} of bindings) key.destroy();
      bindings.length = 0;
      for (const {element, callback} of observers.values())
        hs.ax.removeWatcher(element, events, callback);
      observers.clear();
      timers.stop();
      if (unwatchFailures) unwatchFailures();
      unwatchFailures = null;
      api.providers.stop();
      startup.close();
    },
    status,
    defaults: defaultOptions,
    windows: {select, cycle, move},
    preset,
    space,
    quickApp,
  };
  return session;
}

const accessibilityMessage =
  "Accessibility access is unavailable. Enable Hammerspoon 2 in System Settings > Privacy & Security > Accessibility, then run atelier install to restart";
