"use strict";
const {GroupStore, sameFrame} = require("./GroupStore.js");
const GroupOverlay = require("./GroupOverlay.js");
const {QuickApps} = require("./QuickApps.js");

module.exports = function createAtelier(options) {
  const config = Object.assign({fill: "native-js", padding: 8, pollSeconds: 1, fillQuietMs: 100, fillGraceMs: 300,
    bindSpaces: true, bindGroups: true, groupOverlay: true}, options);
  if (!config.helper) throw new Error("Atelier helper path required");
  const store = new GroupStore();
  const quickApps = new QuickApps(config.quickApps);
  const hotkeys = [], spaceKeys = [], timers = new Set(), watchers = new Map();
  const pending = new Map(), sleepers = new Map(), metrics = [];
  // geometry: pid -> latest AX move/resize event. settling: "pid:id" -> background Fill check.
  const geometry = new Map(), settling = new Map();
  let task = null, input = "", sequence = 0, stopped = true, busy = false, snapshot = null;
  let poll = null, observedFocus = null, generation = 0, observing = false, running = null;
  let overlay = null, overlayRefreshing = false;
  const api = {store, metrics, config, lastError: null, lastResult: null};
  const geometryEvents = ["AXWindowMoved", "AXWindowResized"];
  const events = ["AXFocusedWindowChanged", "AXWindowCreated", "AXUIElementDestroyed",
    "AXWindowMiniaturized", "AXWindowDeminiaturized", "AXWindowResized"];

  function report(error) {
    api.lastError = String(error);
    console.error("Atelier: " + error);
    hs.notify.show("Atelier prototype", String(error));
  }
  function after(seconds, callback) {
    let timer = hs.timer.doAfter(seconds, () => { timers.delete(timer); callback(); });
    timers.add(timer); return timer;
  }
  function sleep(seconds) {
    return new Promise((resolve, reject) => {
      const timer = after(seconds, () => { sleepers.delete(timer); resolve(); });
      sleepers.set(timer, reject);
    });
  }
  function frame(window) {
    const f = window && window.frame;
    return f && {x: f.x, y: f.y, w: f.w, h: f.h};
  }
  function findWindow(member) {
    const matches = w => w.id === member.id && w.pid === member.pid;
    // One app's windows is cheaper than enumerating every window on the system.
    const app = hs.application && hs.application.fromPID ? hs.application.fromPID(member.pid) : null;
    return (app && app.allWindows.find(matches)) || hs.window.allWindows().find(matches);
  }
  function isFocused(member) {
    const focused = hs.window.focusedWindow();
    return !!focused && focused.id === member.id && focused.pid === member.pid;
  }
  function setAX(element, name, value) {
    // HS2 0.0.12 exposes the documented setAttributeValue as setAttributeValueValue.
    const set = element && (element.setAttributeValue || element.setAttributeValueValue);
    return typeof set === "function" && set.call(element, name, value);
  }
  function receive(channel, text) {
    if (channel !== "stdout") { console.error("Atelier helper: " + text); return; }
    input += text;
    let newline;
    while ((newline = input.indexOf("\n")) >= 0) {
      const line = input.slice(0, newline); input = input.slice(newline + 1);
      if (!line.trim()) continue;
      try {
        const response = JSON.parse(line), request = pending.get(response.id);
        if (!request) continue;
        pending.delete(response.id); request.timer.stop(); timers.delete(request.timer);
        metrics.push({command: request.command, ok: response.ok,
          roundTripMs: Date.now() - request.started, nativeMs: response.milliseconds});
        if (metrics.length > 300) metrics.shift();
        response.ok ? request.resolve(response.result) : request.reject(new Error(response.error));
      } catch (e) { report(e); }
    }
  }
  function request(command, args = {}) {
    if (stopped || !task) return Promise.reject(new Error("Atelier is stopped"));
    return new Promise((resolve, reject) => {
      const id = ++sequence;
      const timer = after(30, () => {
        pending.delete(id);
        reject(new Error("Helper timed out; stop and restart the prototype before retrying"));
        api.stop();
      });
      pending.set(id, {resolve, reject, timer, command, started: Date.now()});
      task.sendInput(JSON.stringify({...args, id, command}) + "\n");
    });
  }
  async function refresh() {
    const epoch = generation;
    const result = await request("snapshot");
    if (stopped || generation !== epoch) throw new Error("Atelier stopped");
    snapshot = result;
    snapshot.windows = snapshot.windows.filter(w => w.bundleID !== "net.tenshu.Hammerspoon-2" && !quickApps.bundleIDs.has(w.bundleID));
    store.reconcile(snapshot);
    syncWatchers();
    if (overlay) overlay.update(snapshot, store.current(snapshot));
    return snapshot;
  }
  function refreshOverlay() {
    if (stopped || overlayRefreshing) return;
    overlayRefreshing = true;
    const epoch = generation;
    // A read-only snapshot must not mark the shortcut dispatcher busy: the user
    // may press a number immediately after holding the modifiers.
    refresh().catch(error => {
      if (!stopped && generation === epoch) console.error("Atelier overlay: " + error);
    }).finally(() => { if (generation === epoch) overlayRefreshing = false; });
  }
  function unwatch(entry) {
    for (const event of events) hs.ax.removeWatcher(entry.element, event, entry.listener);
    for (const event of geometryEvents) hs.ax.removeWatcher(entry.element, event, entry.moved);
  }
  function syncWatchers() {
    const pids = new Set(snapshot.windows.map(w => w.pid));
    for (const [pid, entry] of watchers) {
      if (!pids.has(pid)) {
        unwatch(entry); watchers.delete(pid);
      }
    }
    const windows = [...pids].some(pid => !watchers.has(pid)) ? hs.window.allWindows() : [];
    for (const pid of pids) {
      if (watchers.has(pid)) continue;
      const window = windows.find(w => w.pid === pid);
      if (!window || !window.application) continue;
      const element = window.application;
      if (!element) continue;
      const listener = () => observe();
      const moved = () => {
        const last = geometry.get(pid);
        geometry.set(pid, {at: Date.now(), count: last ? last.count + 1 : 1});
      };
      for (const event of events) hs.ax.addWatcher(element, event, listener);
      for (const event of geometryEvents) hs.ax.addWatcher(element, event, moved);
      watchers.set(pid, {element, listener, moved});
    }
  }
  async function run(name, fn, quiet = false) {
    if (stopped) throw new Error("Atelier is stopped");
    // Drop overlapping operations instead of applying a stale target after a queue delay.
    if (busy) {
      metrics.push({command: "dropped:" + name, blockedBy: running, at: Date.now()});
      if (metrics.length > 300) metrics.shift();
      return {busy: true};
    }
    busy = true; running = name;
    const epoch = generation;
    const started = Date.now();
    try {
      const result = await fn();
      api.lastResult = {name, milliseconds: Date.now() - started, result};
      return result;
    } catch (error) {
      if (!quiet && !stopped) report(error);
      throw error;
    } finally {
      metrics.push({command:"action:"+name, roundTripMs:Date.now()-started});
      if (metrics.length > 300) metrics.shift();
      if (generation === epoch) {
        busy = false; running = null;
        if (overlay && overlay.active) refreshOverlay();
      }
    }
  }
  function fire(promise) { promise.catch(() => {}); }
  async function focus(member) {
    const began = Date.now();
    const window = findWindow(member);
    if (!window) throw new Error("Group window disappeared");
    const lookupMs = Date.now() - began;
    const record = route => {
      metrics.push({command: "hsFocus:" + route, window: member.id, at: Date.now(),
        lookupMs, roundTripMs: Date.now() - began});
      if (metrics.length > 300) metrics.shift();
      return window;
    };
    if (isFocused(member)) return record("already");
    // HS2 0.0.12's HSWindow.focus()/raise() and HSApplication.activate() return true
    // without changing focus. Drive the same accessibility attributes directly.
    const app = window.application, element = window.axElement();
    setAX(app && app.axElement(), "AXFrontmost", true);
    setAX(element, "AXMain", true);
    if (element) element.performAction("AXRaise");
    // No native fallback: this prototype tests whether Hammerspoon alone can focus.
    while (Date.now() - began < 500) {
      if (isFocused(member)) return record("ax");
      await sleep(0.005);
    }
    record("failed");
    throw new Error("Hammerspoon could not focus " + (member.app || "window") + " " + member.id);
  }
  function nativeFillJS(window) {
    const root = hs.ax.applicationElement(window.application);
    const menu = root && root.attributeValue("AXMenuBar");
    if (!menu || typeof menu.children !== "function") throw new Error("HS2 AX menu bridging unavailable; use native-helper Fill");
    const queue = [{element: menu, depth: 0}];
    for (let i = 0; i < queue.length && i < 2000; i++) {
      const {element, depth} = queue[i];
      if (element.attributeValue("AXIdentifier") === "_zoomFill:") {
        const focused = hs.window.focusedWindow();
        if (!focused || focused.id !== window.id || focused.pid !== window.pid) throw new Error("Fill target lost focus");
        if (!element.isEnabled || !element.performAction("AXPress")) throw new Error("Native Fill unavailable");
        return;
      }
      if (depth < 7) for (const child of element.children()) queue.push({element: child, depth: depth + 1});
    }
    throw new Error("Native Fill menu item missing");
  }
  async function settle(window, pid, began) {
    // Native tiling animates. Cache the settled frame, never an intermediate one.
    // Settled: no frame change or AX move/resize event for fillQuietMs after one was
    // seen, or no movement at all within fillGraceMs (for example, already filled).
    const eventAt = () => (geometry.get(pid) || {at: 0}).at;
    let previous = frame(window), lastChange = began, changed = false, firstChangeMs = null;
    while (Date.now() - began < 3000) {
      await sleep(0.02);
      const now = Date.now(), current = frame(window), event = eventAt();
      const moved = !sameFrame(previous, current, 0);
      if (moved || event > lastChange) {
        if (!changed) firstChangeMs = now - began;
        changed = true; previous = current;
        lastChange = Math.max(lastChange, event, moved ? now : 0);
      }
      if (changed ? now - lastChange >= config.fillQuietMs : now - began >= config.fillGraceMs) {
        return {frame: current, changed, firstChangeMs};
      }
    }
    throw new Error("Window frame did not settle after Fill");
  }
  async function fill(member, window = findWindow(member)) {
    if (!window) throw new Error("Fill window disappeared");
    const key = member.pid + ":" + member.id;
    if (member.fillFailed || settling.has(key) || sameFrame(member.filledFrame, frame(window))) return;
    if (!isFocused(member)) return;
    const began = Date.now(), epoch = generation, mode = config.fill;
    const eventCount = () => (geometry.get(member.pid) || {count: 0}).count, eventsBefore = eventCount();
    try {
      if (mode === "native-js") nativeFillJS(window);
      else if (mode === "native-helper") {
        await request("fill", {window: member.id, pid: member.pid, space: member.space});
      } else if (mode === "padded") {
        const usable = window.screen.frame, p = config.padding;
        window.frame = new HSRect(usable.x + p, usable.y + p, usable.w - 2 * p, usable.h - 2 * p);
      } else throw new Error("Unknown Fill mode: " + mode);
    } catch (e) { member.fillFailed = true; throw e; }
    const pressMs = Date.now() - began;
    // Confirm the result in the background so the operation lock is released now.
    // The settling entry keeps a second Fill of this window from overlapping.
    const job = settle(window, member.pid, began).then(result => {
      if (mode === "padded") {
        const f = window.screen.frame, p = config.padding;
        if (!sameFrame(result.frame, {x: f.x+p, y:f.y+p, w:f.w-2*p, h:f.h-2*p}, 2)) {
          throw new Error("App rejected the requested padded frame");
        }
      }
      member.filledFrame = result.frame;
      metrics.push({command: "fill:" + mode, window: member.id, ok: true, pressMs,
        changed: result.changed, firstChangeMs: result.firstChangeMs,
        axEvents: eventCount() - eventsBefore, roundTripMs: Date.now() - began});
    }).catch(error => {
      if (stopped || generation !== epoch) return;
      member.fillFailed = true;
      metrics.push({command: "fill:" + mode, window: member.id, ok: false, roundTripMs: Date.now() - began});
      report(error);
    }).finally(() => {
      if (settling.get(key) === job) settling.delete(key);
      if (metrics.length > 300) metrics.shift();
    });
    settling.set(key, job);
  }
  async function activate(snapshot, group, member) {
    const window = await focus(member);
    // Redraw the highlight as soon as focus lands. The first Fill of a member can
    // spend about 500 ms settling, and the overlay would otherwise wait for it.
    if (overlay && overlay.active) overlay.update(snapshot, group);
    await fill(member, window);
  }
  function observe() {
    // Keeps Group membership current and Fills a newly focused member. It does not
    // take the operation lock, so shortcuts keep working while it runs. It skips
    // while an operation runs (that operation refreshes anyway) and never overlaps itself.
    if (stopped || busy || observing || !store.groups.size) return;
    observing = true;
    const epoch = generation;
    (async () => {
      const s = await refresh(), group = store.current(s);
      const member = group && group.members.find(w => w.id === s.focused);
      // A switch may have moved focus while the snapshot was in flight; the next pass sees it.
      if (member && !isFocused(member)) return;
      const identity = member ? `${member.pid}:${member.id}` : null;
      if (member && identity !== observedFocus) await fill(member);
      observedFocus = identity;
    })().catch(error => {
      if (!stopped && generation === epoch) report(error);
    }).finally(() => { if (generation === epoch) observing = false; });
  }
  api.probe = () => run("probe", refresh);
  api.quickApps = () => quickApps.status();
  api.quickApp = app => run("quickApp", async () => {
    const result = await quickApps.toggle(app, request);
    await refresh();
    return result;
  });
  api.overlayStatus = () => ({enabled:!!overlay, active:!!(overlay && overlay.active),
    showing:!!(overlay && overlay.canvas && overlay.canvas.isShowing()),
    frame:overlay && overlay.canvas ? overlay.canvas.frame() : null,
    renders:overlay ? overlay.renders : []});
  api.group = () => run("group", async () => {
    const s = await refresh(), group = store.group(s);
    const member = group.members.find(w => w.id === s.focused) || group.members[0];
    await activate(s, group, member); return group;
  });
  api.select = number => run("select", async () => {
    const s = await refresh(), group = store.current(s), member = group && group.members[number - 1];
    if (!member) return {noop:true};
    await activate(s, group, member); return {window:member.id};
  });
  api.cycle = offset => run("cycle", async () => {
    const s = await refresh(), group = store.current(s);
    if (!group || !group.members.length) return {noop:true};
    const index = group.members.findIndex(w => w.id === s.focused);
    const member = group.members[(index + offset + group.members.length) % group.members.length];
    await activate(s, group, member); return {window:member.id};
  });
  api.reorderMember = offset => run("reorderMember", async () => {
    const s = await refresh(), group = store.current(s);
    if (group) store.moveMember(group, s.focused, offset);
    return group;
  });
  api.setFill = mode => {
    if (!["native-js", "native-helper", "padded"].includes(mode)) throw new Error("Unknown Fill mode");
    config.fill = mode;
    for (const group of store.groups.values()) for (const member of group.members) {
      member.filledFrame = null; member.fillFailed = false;
    }
  };
  api.space = (command, args = {}) => run(command, async () => {
    const s = await refresh(), d = s.displays.find(d => d.id === s.targetDisplay);
    if (!d) throw new Error("No target display");
    for (const key of spaceKeys) key.disable();
    try {
      const result = await request(command, {...args, display:d.id, current:d.current});
      await refresh(); return result;
    } finally {
      if (!stopped) for (const key of spaceKeys) if (!key.enable()) report("Failed to restore a Space shortcut");
    }
  });
  api.move = () => Promise.reject(new Error("Window movement between Spaces is disabled in this prototype"));
  function bind(mods, key, callback, space = false) {
    const hotkey = hs.hotkey.create(mods, key, () => fire(callback()), null, null);
    if (!hotkey || !hotkey.enable()) {
      if (hotkey) hotkey.destroy();
      throw new Error("Shortcut unavailable: " + mods.join("+") + "+" + key);
    }
    hotkeys.push(hotkey); if (space) spaceKeys.push(hotkey);
  }
  api.start = async () => {
    if (!stopped) return api;
    stopped = false; input = ""; busy = false; generation++;
    const launched = hs.task.create(config.helper, ["--hs2-bridge"], (code, reason) => {
      if (!stopped && task === launched) { report("Helper exited: " + code + " " + reason); api.stop(); }
    }, null, receive);
    task = launched.start();
    try {
      const s = await refresh();
      if (!s.trusted) throw new Error("Grant Accessibility access to Hammerspoon 2, then restart Atelier");
      await quickApps.resolve(request);
      await refresh();
      for (let n = 1; n <= 10; n++) {
        const key = String(n % 10);
        if (config.bindSpaces) bind(["alt"], key, () => api.space("switch", {number:n}), true);
        if (config.bindGroups) bind(["cmd","alt"], key, () => api.select(n));
      }
      if (config.bindSpaces) {
        bind(["alt"], "`", () => api.space("create"), true);
        bind(["ctrl","alt"], "left", () => api.space("reorder", {offset:-1}), true);
        bind(["ctrl","alt"], "right", () => api.space("reorder", {offset:1}), true);
        bind(["ctrl","alt"], "delete", () => api.space("delete"), true);
      }
      if (config.bindGroups) {
        bind(["cmd","alt"], "g", api.group);
        bind(["cmd","alt"], "[", () => api.cycle(-1));
        bind(["cmd","alt"], "]", () => api.cycle(1));
        if (config.groupOverlay) {
          overlay = new GroupOverlay(hs, refreshOverlay);
          overlay.start();
        }
      }
      quickApps.bind(hs.hotkey, bind, api.quickApp);
      poll = hs.timer.doEvery(config.pollSeconds, observe);
      console.log("Atelier HS2 prototype ready; Fill=" + config.fill);
      return api;
    } catch (error) { api.stop(); report(error); throw error; }
  };
  api.stop = () => {
    stopped = true;
    generation++; busy = false; observing = false; running = null;
    if (overlay) overlay.stop(); overlay = null; overlayRefreshing = false;
    if (poll) poll.stop(); poll = null;
    for (const key of hotkeys) key.destroy(); hotkeys.length = 0; spaceKeys.length = 0;
    for (const entry of watchers.values()) unwatch(entry);
    watchers.clear(); settling.clear(); geometry.clear();
    for (const timer of timers) timer.stop(); timers.clear();
    for (const reject of sleepers.values()) reject(new Error("Atelier stopped")); sleepers.clear();
    for (const p of pending.values()) p.reject(new Error("Atelier stopped")); pending.clear();
    if (task) task.terminate(); task = null;
    return "Atelier stopped; shortcuts released";
  };
  return api;
};
