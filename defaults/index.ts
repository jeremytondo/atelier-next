// The Atelier defaults: Groups, Desktop shortcuts, Quick Apps, and the overlay,
// as policy over `hs.*` and the API. One session owns every binding, observer,
// timer, and the providers process; stopping releases all of them and leaves
// independent HS2 scripts untouched.
import type {ResolvedApplication} from "../api/application.ts";
import type {HS} from "../api/hs.ts";
import type {AtelierAPI} from "../api/index.ts";
import type {Snapshot} from "../api/spaces.ts";
import {Timers} from "../api/timers.ts";
import {setAXAttribute} from "./accessibility.ts";
import {
  type Binding,
  type Config,
  defaults as defaultOptions,
  normalize,
  type Options,
  type QuickAppEntry,
  shortcut,
} from "./configuration.ts";
import {type Group, Groups, identity, type Member, sameFrame} from "./groups.ts";
import {Overlay} from "./overlay.ts";
import {liveWorkspace, QuickApps, type ToggleResult, type Workspace} from "./quick-apps.ts";
import {Startup} from "./startup.ts";
import {StateFile} from "./state.ts";

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

export interface Status {
  state: State;
  error: string | null;
  version: string;
  hammerspoon2: {build: string; expectedBuild: string};
  quickApps: {app: string; bundleID: string; shortcut: string}[];
  groups: number;
  /** The Groups state file, its last write in this context, and the start-up restore result. */
  groupsFile: {
    path: string;
    savedAt: string | null;
    restored: number | null;
    dropped: number | null;
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
  group(): Promise<Group | Busy>;
  select(number: number): Promise<{window: number} | Noop | Busy>;
  cycle(offset: number): Promise<{window: number} | Noop | Busy>;
  space(
    command: SpaceAction,
    args?: {number?: number; offset?: -1 | 1},
  ): Promise<Snapshot | Noop | Busy>;
  quickApp(app: string): Promise<ToggleResult | Busy>;
}

type QuickApp = QuickAppEntry & ResolvedApplication;

const events = [
  "AXFocusedWindowChanged",
  "AXWindowCreated",
  "AXUIElementDestroyed",
  "AXWindowMiniaturized",
  "AXWindowDeminiaturized",
  "AXWindowResized",
  "AXWindowMoved",
];
const spaceActions: SpaceAction[] = ["switch", "create", "reorder", "delete"];

export function createDefaults(hs: HS, api: AtelierAPI, info: DefaultsInfo): Defaults {
  const groups = new Groups(),
    file = new StateFile(hs),
    timers = new Timers(hs),
    startup = new Startup(hs);
  const bindings: {key: HSHotkey; space: boolean}[] = [],
    observers = new Map<number, {element: HSAXElement; callback: () => void}>(),
    settling = new Set<string>(),
    geometry = new Map<number, number>(),
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
    quick: QuickApps | null = null,
    quickApps: QuickApp[] = [],
    startOptions: Options | undefined,
    observedFocus: string | null = null,
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
  function focused(member: Member) {
    const window = hs.window.focusedWindow();
    return !!window && window.id === member.id && window.pid === member.pid;
  }
  function find(member: Member) {
    const app = hs.application.fromPID(member.pid);
    return app?.allWindows.find((w) => w.id === member.id && w.pid === member.pid);
  }
  function redraw() {
    if (overlay && snapshot) overlay.update(snapshot, groups.current(snapshot));
  }
  function persist() {
    if (persisting) file.save(groups.serialize());
  }
  function restore(first: Snapshot) {
    restored = null;
    const read = file.read();
    if (read.status === "missing") {
      console.log("Atelier: No saved Groups at " + file.path);
    } else if (read.status !== "ok") {
      console.log("Atelier: Ignoring " + read.status + " Groups state at " + file.path);
    } else {
      restored = groups.restore(read.groups, first);
      syncObservers();
      redraw();
      console.log(
        "Atelier: Restored " + restored.restored + " Groups, dropped " + restored.dropped,
      );
    }
    persisting = true;
    persist();
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
    groups.reconcile(next);
    persist();
    syncObservers();
    redraw();
    return next;
  }
  function syncObservers() {
    if (!config.groups || !groups.entries.size || !snapshot) return;
    const pids = new Set(snapshot.windows.map((w) => w.pid));
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
        geometry.set(pid, Date.now());
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
  async function focus(member: Member, epoch: number): Promise<HSWindow> {
    const window = find(member);
    if (!window) throw new Error("The selected window closed");
    if (!focused(member)) {
      setAXAttribute(window.application?.axElement(), "AXFrontmost", true);
      setAXAttribute(window.axElement(), "AXMain", true);
      window.axElement().performAction("AXRaise");
      const began = Date.now();
      while (!focused(member) && Date.now() - began < 500) {
        await timers.sleep(0.005);
        assertValid(epoch);
      }
      if (!focused(member)) throw new Error("Could not focus the exact window in " + member.app);
    }
    return window;
  }
  function pressFill(window: HSWindow, member: Member) {
    const application = window.application;
    const root = application && hs.ax.applicationElement(application),
      menu = root?.attributeValue("AXMenuBar") as HSAXElement | null | undefined;
    if (!menu || typeof menu.children !== "function")
      throw new Error("Native Fill menu is unavailable in " + member.app);
    const queue: {element: HSAXElement; depth: number}[] = [{element: menu, depth: 0}];
    for (let i = 0; i < queue.length && i < 2000; i++) {
      const item = queue[i];
      if (!item) break;
      const {element, depth} = item;
      if (element.attributeValue("AXIdentifier") === "_zoomFill:") {
        if (!focused(member)) throw new Error("Fill target lost focus");
        if (!element.isEnabled || !element.performAction("AXPress"))
          throw new Error("Native Fill is unavailable in " + member.app);
        return;
      }
      if (depth < 7)
        for (const child of element.children()) queue.push({element: child, depth: depth + 1});
    }
    throw new Error("Native Fill is not supported by " + member.app);
  }
  function fill(member: Member, window: HSWindow | undefined, epoch: number) {
    const key = identity(member);
    if (
      !window ||
      !focused(member) ||
      member.fillFailed ||
      settling.has(key) ||
      sameFrame(member.filledFrame, window.frame)
    )
      return;
    try {
      pressFill(window, member);
    } catch (error) {
      member.fillFailed = true;
      throw error;
    }
    settling.add(key);
    const began = Date.now();
    (async () => {
      let previous = window.frame,
        changed = false,
        lastChange = began;
      while (Date.now() - began < 3000) {
        await timers.sleep(0.02);
        assertValid(epoch);
        const current = window.frame,
          now = Date.now(),
          event = geometry.get(member.pid) || 0;
        const moved = !sameFrame(previous, current, 0);
        if (moved || event > lastChange) {
          changed = true;
          lastChange = Math.max(lastChange, event, moved ? now : 0);
          previous = current;
        }
        if (current && (changed ? now - lastChange >= 100 : now - began >= 300)) {
          member.filledFrame = {x: current.x, y: current.y, w: current.w, h: current.h};
          persist();
          return;
        }
      }
      throw new Error("Native Fill did not settle in " + member.app);
    })()
      .catch((error) => {
        if (valid(epoch)) {
          member.fillFailed = true;
          report(error);
        }
      })
      .finally(() => {
        if (generation === epoch) settling.delete(key);
      });
  }
  async function activate(group: Group, member: Member, epoch: number) {
    const window = await focus(member, epoch);
    assertValid(epoch);
    redraw();
    // Revalidate topology after asynchronous focus before changing window geometry.
    const latest = await refresh(epoch),
      current = groups.current(latest);
    if (
      !current ||
      current.display !== group.display ||
      current.space !== group.space ||
      !current.members.some((w) => identity(w) === identity(member))
    )
      throw new Error("The window or Desktop changed during selection");
    fill(member, window, epoch);
  }
  function observe() {
    if (state !== "Running" || busy || observing || !groups.entries.size) return;
    observing = true;
    const epoch = generation;
    refresh(epoch)
      .then((next) => {
        if (busy) return;
        const group = groups.current(next),
          member = group?.members.find((w) => w.id === next.focused);
        const key = member && identity(member);
        if (member && focused(member) && key !== observedFocus) fill(member, find(member), epoch);
        observedFocus = key ?? null;
      })
      .catch((error) => {
        if (valid(epoch)) report(error);
      })
      .finally(() => {
        if (generation === epoch) observing = false;
      });
  }
  const group = () =>
    run("group", async (epoch) => {
      const next = await refresh(epoch),
        entry = groups.repair(next);
      syncObservers();
      const member = entry.members.find((w) => w.id === next.focused) || entry.members[0];
      if (member) await activate(entry, member, epoch);
      return entry;
    });
  const select = (number: number) =>
    run("select", async (epoch): Promise<{window: number} | Noop> => {
      const next = await refresh(epoch),
        entry = groups.current(next),
        member = entry?.members[number - 1];
      if (!entry || !member) return {noop: true};
      await activate(entry, member, epoch);
      return {window: member.id};
    });
  const cycle = (offset: number) =>
    run("cycle", async (epoch): Promise<{window: number} | Noop> => {
      const next = await refresh(epoch),
        entry = groups.current(next);
      if (!entry?.members.length) return {noop: true};
      const current = entry.members.findIndex((w) => w.id === next.focused);
      const member =
        entry.members[(current + offset + entry.members.length) % entry.members.length];
      if (!member) return {noop: true};
      await activate(entry, member, epoch);
      return {window: member.id};
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
    groups: groups.entries.size,
    groupsFile: {
      path: file.path,
      savedAt: file.savedAt,
      restored: restored?.restored ?? null,
      dropped: restored?.dropped ?? null,
    },
    metrics,
  });
  function bind(binding: Binding | QuickApp, action: () => Promise<unknown>) {
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
    bindings.push({key, space: "space" in binding && binding.space});
  }
  const actions: Record<string, () => Promise<unknown>> = {
    group,
    "cycle-previous": () => cycle(-1),
    "cycle-next": () => cycle(1),
    // Stop first so pending Groups state reaches disk before the context goes.
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
        quick = new QuickApps((info.workspace ?? ((t) => liveWorkspace(hs, api, t)))(timers));
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
        const first = await refresh(epoch);
        if (config.groups) restore(first);
        for (const binding of config.shortcuts) {
          const action = actions[binding.name];
          if (!action) throw new Error("Unknown binding: " + binding.name);
          bind(binding, action);
        }
        for (const entry of quickApps) bind(entry, () => quickApp(entry.bundleID));
        if (config.groups && config.overlay) {
          overlay = new Overlay(hs, config.overlayFlags, () => {
            redraw();
            observe();
          });
          overlay.start();
        }
        state = "Running";
        console.log("Atelier: Running");
        requestNotifications();
        poll = hs.timer.doEvery(1, observe);
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
      busy = observing = false;
      observedFocus = null;
      if (poll) poll.stop();
      poll = null;
      if (overlay) overlay.stop();
      overlay = null;
      quick = null;
      for (const {key} of bindings) key.destroy();
      bindings.length = 0;
      for (const {element, callback} of observers.values())
        hs.ax.removeWatcher(element, events, callback);
      observers.clear();
      geometry.clear();
      settling.clear();
      timers.stop();
      if (unwatchFailures) unwatchFailures();
      unwatchFailures = null;
      api.providers.stop();
      startup.close();
    },
    status,
    defaults: defaultOptions,
    group,
    select,
    cycle,
    space,
    quickApp,
  };
  return session;
}

const accessibilityMessage =
  "Accessibility access is unavailable. Enable Hammerspoon 2 in System Settings > Privacy & Security > Accessibility, then run atelier install to restart";
