"use strict";
// The default Atelier workspace is policy over HS2. Native code supplies Space
// topology/lifecycle and Quick App gaps; HS2 owns bindings, focus, Fill, and UI.
const {defaults, normalize, shortcut} = require("./configuration.js");
const {Groups, identity, sameFrame} = require("./groups.js");
const {Bridge, Timers} = require("./bridge.js");
const {Overlay} = require("./overlay.js");

function create(hs, host) {
  const groups = new Groups(),
    timers = new Timers(hs);
  const bindings = [],
    observers = new Map(),
    settling = new Set(),
    geometry = new Map();
  let config = normalize(),
    generation = 0,
    busy = false,
    observing = false,
    snapshot = null;
  let poll = null,
    overlay = null,
    quickApps = [],
    startOptions = {},
    observedFocus = null;
  const api = {state: "Paused", lastError: null, defaults, ready: Promise.resolve(), metrics: []};
  const bridge = new Bridge(
    hs,
    host.helper,
    (error) => {
      api.stop();
      report(error);
    },
    host.helperArguments,
  );
  const events = [
    "AXFocusedWindowChanged",
    "AXWindowCreated",
    "AXUIElementDestroyed",
    "AXWindowMiniaturized",
    "AXWindowDeminiaturized",
    "AXWindowResized",
    "AXWindowMoved",
  ];
  const valid = (epoch) => generation === epoch && ["Starting", "Running"].includes(api.state);
  function assertValid(epoch) {
    if (!valid(epoch)) throw new Error("Atelier session changed");
  }
  function record(name, began) {
    api.metrics.push({name, milliseconds: Date.now() - began});
    if (api.metrics.length > 100) api.metrics.shift();
  }
  function state(value) {
    api.state = value;
    if (host.status) host.status(value, api.lastError || "");
  }
  function report(error) {
    api.lastError = String(error.message || error);
    console.error("Atelier: " + api.lastError);
    if (host.status) host.status(api.state, api.lastError);
    // Notifications are optional; the HS2 Console always retains the error.
    try {
      hs.notify.show("Atelier", api.lastError);
    } catch (_) {
      /* notifications may be denied */
    }
  }
  function fire(promise) {
    promise.catch(() => {});
  }
  function focused(member) {
    const window = hs.window.focusedWindow();
    return !!window && window.id === member.id && window.pid === member.pid;
  }
  function find(member) {
    const app = hs.application.fromPID(member.pid);
    return app?.allWindows.find((w) => w.id === member.id && w.pid === member.pid);
  }
  function redraw() {
    if (overlay && snapshot) overlay.update(snapshot, groups.current(snapshot));
  }
  async function refresh(epoch) {
    const next = await bridge.request("snapshot");
    assertValid(epoch);
    if (!next.trusted)
      throw new Error("Grant Accessibility access to Atelier, then choose Reload Config");
    const excluded = new Set(quickApps.map((app) => app.bundleID));
    next.windows = next.windows.filter(
      (w) => w.bundleID !== host.bundleID && !excluded.has(w.bundleID),
    );
    snapshot = next;
    groups.reconcile(next);
    syncObservers();
    redraw();
    return next;
  }
  function syncObservers() {
    if (!config.groups || !groups.entries.size) return;
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
      // HS2 after 0.0.12 watches AX elements, including application elements;
      // retain the same element and callback for symmetric removal.
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
  async function run(name, action) {
    if (api.state !== "Running")
      throw new Error("Atelier defaults are paused; choose Resume or Reload Config");
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
  function setAX(element, name, value) {
    // The tested release exports this setter with its argument name appended.
    const setter = element && (element.setAttributeValue || element.setAttributeValueValue);
    return setter?.call(element, name, value);
  }
  async function focus(member, epoch) {
    const window = find(member);
    if (!window) throw new Error("The selected window closed");
    if (!focused(member)) {
      setAX(window.application.axElement(), "AXFrontmost", true);
      setAX(window.axElement(), "AXMain", true);
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
  function pressFill(window, member) {
    const root = hs.ax.applicationElement(window.application),
      menu = root?.attributeValue("AXMenuBar");
    if (!menu || typeof menu.children !== "function")
      throw new Error("Native Fill menu is unavailable in " + member.app);
    const queue = [{element: menu, depth: 0}];
    for (let i = 0; i < queue.length && i < 2000; i++) {
      const {element, depth} = queue[i];
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
  function fill(member, window, epoch) {
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
          member.filledFrame = {...current};
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
  async function activate(group, member, epoch) {
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
    if (api.state !== "Running" || busy || observing || !groups.entries.size) return;
    observing = true;
    const epoch = generation;
    refresh(epoch)
      .then((next) => {
        if (busy) return;
        const group = groups.current(next),
          member = group?.members.find((w) => w.id === next.focused);
        const key = member && identity(member);
        if (member && focused(member) && key !== observedFocus) fill(member, find(member), epoch);
        observedFocus = key;
      })
      .catch((error) => {
        if (valid(epoch)) report(error);
      })
      .finally(() => {
        if (generation === epoch) observing = false;
      });
  }
  api.group = () =>
    run("group", async (epoch) => {
      const next = await refresh(epoch),
        group = groups.repair(next);
      syncObservers();
      const member = group.members.find((w) => w.id === next.focused) || group.members[0];
      if (member) await activate(group, member, epoch);
      return group;
    });
  api.select = (number) =>
    run("select", async (epoch) => {
      const next = await refresh(epoch),
        group = groups.current(next),
        member = group?.members[number - 1];
      if (!member) return {noop: true};
      await activate(group, member, epoch);
      return {window: member.id};
    });
  api.cycle = (offset) =>
    run("cycle", async (epoch) => {
      const next = await refresh(epoch),
        group = groups.current(next);
      if (!group?.members.length) return {noop: true};
      const current = group.members.findIndex((w) => w.id === next.focused);
      const member =
        group.members[(current + offset + group.members.length) % group.members.length];
      await activate(group, member, epoch);
      return {window: member.id};
    });
  const spaceActions = ["switch", "create", "reorder", "delete"];
  api.space = (command, args = {}) =>
    run(command, async (epoch) => {
      if (!spaceActions.includes(command)) throw new Error("Unknown Space action");
      const next = await refresh(epoch),
        display = next.displays.find((d) => d.id === next.targetDisplay);
      if (!display) throw new Error("No target display");
      const spaceKeys = bindings.filter((b) => b.space);
      for (const {key} of spaceKeys) key.disable();
      try {
        const result = await bridge.request(command, {
          ...args,
          display: display.id,
          current: display.current,
        });
        await refresh(epoch);
        return result;
      } finally {
        if (valid(epoch)) {
          for (const {key} of spaceKeys) {
            if (key.enable()) continue;
            api.stop();
            report(new Error("Could not restore Desktop shortcuts; choose Resume"));
            break;
          }
        }
      }
    });
  api.quickApp = (app) =>
    run("quickApp", async (epoch) => {
      const entry = quickApps.find((e) => e.app === app || e.bundleID === app);
      if (!entry) throw new Error("Quick App is not configured: " + app);
      const result = await bridge.request("quickToggle", {
        app: entry.app,
        expectedBundleID: entry.bundleID,
        ...(entry.size ? {size: entry.size} : {}),
      });
      await refresh(epoch);
      return result;
    });
  api.native = (command, args) =>
    spaceActions.includes(command)
      ? api.space(command, args)
      : run("native:" + command, () => bridge.request(command, args));
  api.status = () => ({
    state: api.state,
    error: api.lastError,
    version: host.version,
    quickApps: quickApps.map((a) => ({app: a.app, bundleID: a.bundleID, shortcut: a.shortcut})),
    groups: groups.entries.size,
    metrics: api.metrics,
  });
  api.helperRunning = () => !!(bridge.task?.isRunning || bridge.retiring?.isRunning);
  function bind(binding, action) {
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
    bindings.push({key, space: !!binding.space});
  }
  const actions = {
    group: api.group,
    "cycle-previous": () => api.cycle(-1),
    "cycle-next": () => api.cycle(1),
    "reload-config": () => hs.reload(),
    "desktop-create": () => api.space("create"),
    "desktop-left": () => api.space("reorder", {offset: -1}),
    "desktop-right": () => api.space("reorder", {offset: 1}),
    "desktop-delete": () => api.space("delete"),
  };
  for (let n = 1; n <= 10; n++) {
    actions["desktop-" + n] = () => api.space("switch", {number: n});
    actions["select-" + n] = () => api.select(n);
  }
  api.start = (options) => {
    if (api.state === "Running" || api.state === "Starting") return api.ready;
    if (options !== undefined) startOptions = options;
    const epoch = ++generation;
    api.lastError = null;
    state("Starting");
    api.ready = (async () => {
      config = normalize(startOptions);
      if (config.launchAtLogin !== null && host.setLogin) host.setLogin(config.launchAtLogin);
      const hello = await bridge.start();
      assertValid(epoch);
      if (!hello.trusted)
        throw new Error("Grant Accessibility access to Atelier, then choose Reload Config");
      quickApps = [];
      const seen = new Set();
      for (const entry of config.quickApps) {
        try {
          const resolved = await bridge.request("quickResolve", {app: entry.app});
          assertValid(epoch);
          if (seen.has(resolved.bundleID)) throw new Error("Duplicate Quick App: " + entry.app);
          seen.add(resolved.bundleID);
          quickApps.push({...entry, ...resolved});
        } catch (error) {
          assertValid(epoch);
          report(error);
        }
      }
      await refresh(epoch);
      for (const binding of config.shortcuts) bind(binding, actions[binding.name]);
      for (const entry of quickApps) bind(entry, () => api.quickApp(entry.bundleID));
      if (config.groups && config.overlay) {
        overlay = new Overlay(hs, config.overlayFlags, () => {
          redraw();
          observe();
        });
        overlay.start();
      }
      state("Running");
      poll = hs.timer.doEvery(1, observe);
      return api;
    })().catch((error) => {
      if (generation === epoch) {
        api.stop();
        state("Stopped");
        report(error);
      }
      throw error;
    });
    return api.ready;
  };
  api.stop = () => {
    generation++;
    state("Paused");
    busy = observing = false;
    observedFocus = null;
    if (poll) poll.stop();
    poll = null;
    if (overlay) overlay.stop();
    overlay = null;
    for (const {key} of bindings) key.destroy();
    bindings.length = 0;
    for (const {element, callback} of observers.values())
      hs.ax.removeWatcher(element, events, callback);
    observers.clear();
    geometry.clear();
    settling.clear();
    timers.stop();
    bridge.stop();
  };
  return api;
}
module.exports = {create};
