import assert from "node:assert/strict";
import {test} from "node:test";
import type {HS} from "../api/hs.ts";
import {createAPI} from "../api/index.ts";
import type {Snapshot, WindowInfo} from "../api/spaces.ts";
import {normalize, type PresetOption, shortcut} from "../defaults/configuration.ts";
import {createDefaults, type DefaultsInfo, waitingSeconds} from "../defaults/index.ts";
import {parse} from "../defaults/state.ts";
import {
  isWindow,
  type MoveTarget,
  moveTarget,
  WindowLists,
  windowsOf,
} from "../defaults/windows.ts";
import {FakeWorkspace} from "./fake-workspace.ts";
import {type FakeState, fakeApp, fakeHS, fakeMac, inventoried} from "./fakes.ts";

const options = {overlay: false, quickApps: []};
const path = "/Users/fake/Library/Application Support/Atelier/windows.json";
const window = (id: number, pid: number, space: string, extra: Partial<WindowInfo> = {}) =>
  inventoried(id, pid, {app: "", bundleID: "", spaces: [space], ...extra});
const snap = (
  current: string,
  windows: WindowInfo[],
  extra: Partial<Snapshot> & {fullscreen?: string[]} = {},
): Snapshot => ({
  trusted: true,
  focused: 0,
  focusedSpace: current,
  targetDisplay: "D",
  missionControl: false,
  displays: [
    {
      id: "D",
      current,
      spaces: ["1", "2", ...(extra.fullscreen ?? [])].map((id) => ({
        id,
        fullscreen: extra.fullscreen?.includes(id) ?? false,
      })),
    },
  ],
  windows,
  complete: true,
  ...extra,
});
const ids = (store: WindowLists, key: string) =>
  windowsOf(store.entries.get(key)!).map((w) => w.id) ?? null;
function session(hs: HS, extra: Partial<DefaultsInfo> = {}) {
  const api = createAPI(hs, {providers: "/share/atelier/atelier-providers"});
  return createDefaults(hs, api, {expectedBuild: "133.1", version: "test", ...extra});
}
/** Resolves `pending` while firing the short sleeps a focus attempt waits on. */
async function pumped<T>(state: FakeState, pending: Promise<T>): Promise<T> {
  let settled = false;
  pending.then(
    () => {
      settled = true;
    },
    () => {
      settled = true;
    },
  );
  while (!settled) {
    for (const timer of state.timers.filter((t) => !t.stopped && !t.repeats && t.seconds < 0.01)) {
      timer.stopped = true;
      timer.callback();
    }
    await new Promise((resolve) => setImmediate(resolve));
  }
  return pending;
}

test("custom bindings replace defaults, support disabling, and detect aliases", () => {
  const config = normalize({
    ...options,
    bindings: {"desktop-create": "ctrl-option-n", "select-1": "none"},
  });
  assert.equal(config.shortcuts.find((b) => b.name === "desktop-create")!.key, "n");
  assert.ok(!config.shortcuts.some((b) => b.name === "select-1"));
  const move = (name: string, c = config) => c.shortcuts.find((b) => b.name === name);
  assert.deepEqual([move("move-1")!.mods, move("move-1")!.key], [["cmd", "alt", "shift"], "1"]);
  assert.deepEqual(
    [move("move-10")!.key, move("move-previous")!.key, move("move-next")!.key],
    ["0", "[", "]"],
  );
  const custom = normalize({bindings: {"select-1": "cmd-1", "move-next": "none"}});
  assert.equal(move("move-1", custom)!.identity, move("move-1")!.identity);
  assert.equal(move("move-next", custom), undefined);
  assert.equal(
    normalize({windows: false}).shortcuts.some((b) => b.name.startsWith("move-")),
    false,
  );
  assert.throws(
    () => normalize({bindings: {"move-1": "cmd-option-1"}}),
    /move-1 conflicts with select-1/,
  );
  assert.equal(shortcut("command-option-minus").identity, shortcut("alt-cmd--").identity);
  assert.throws(() => normalize({bindings: {"desktop-create": "alt-1"}}), /conflicts/);
  assert.throws(
    () => normalize({quickApps: [{app: "Calculator", shortcut: "cmd-alt-p"}]}),
    /conflicts with presets/,
  );
  assert.throws(
    () => normalize({quickApps: [{app: "A", shortcut: "cmd-a", size: {width: -1, height: 20}}]}),
    /size/,
  );
  assert.throws(() => normalize({launchAtLogin: true}), /Unknown Atelier option/);
  assert.throws(() => normalize({groups: true}), /Unknown Atelier option: groups/);
  assert.throws(() => normalize({bindings: {group: "cmd-option-g"}}), /Unknown binding: group/);
});

test("a Desktop's first list puts the focused window first, then visible ones, then the rest", () => {
  const store = new WindowLists();
  store.reconcile(
    snap(
      "1",
      [
        window(1, 10, "1", {onScreen: false}),
        window(2, 10, "1"),
        window(3, 11, "1"),
        window(4, 12, "1", {onScreen: false}),
        window(5, 13, "2"),
        window(6, 14, "1", {ordinary: false}),
        window(7, 15, "1", {ordinary: undefined}),
        window(8, 16, "", {spaces: []}),
        window(9, 17, "9"),
      ],
      {focused: 3, fullscreen: ["9"]},
    ),
  );
  assert.deepEqual(ids(store, "D:1"), [3, 2, 1, 4]);
  assert.deepEqual(ids(store, "D:2"), [5]);
  assert.equal(store.entries.size, 2);
  // A fullscreen Space is not a Desktop: nothing to focus there.
  assert.equal(store.focused(snap("9", [], {fullscreen: ["9"]})), undefined);
  assert.deepEqual(
    windowsOf(store.focused(snap("2", []))!).map((w) => w.id),
    [5],
  );
});

test("arrivals append, closures and departures compact, and weak evidence changes nothing", () => {
  const store = new WindowLists();
  const listed = () => ids(store, "D:1");
  store.reconcile(snap("1", [window(1, 10, "1"), window(2, 11, "1")], {focused: 1}));
  // Focus moves and a window hides: the order stays and the entry stays.
  store.reconcile(
    snap("1", [window(1, 10, "1", {onScreen: false}), window(2, 11, "1")], {
      focused: 2,
    }),
  );
  assert.deepEqual(listed(), [1, 2]);
  // Accessibility loses sight of a listed window, or calls it a dialog; the census
  // still has it, so it stays. Unknown membership keeps it too.
  store.reconcile(
    snap("1", [
      window(1, 10, "1", {ordinary: undefined}),
      window(2, 11, "1", {ordinary: false, spaces: []}),
    ]),
  );
  assert.deepEqual(listed(), [1, 2]);
  assert.deepEqual(
    windowsOf(store.entries.get("D:1")!).map((w) => w.visible),
    [true, true],
  );
  // Arrivals append in census order, ahead of nothing.
  store.reconcile(
    snap("1", [window(3, 12, "1"), window(1, 10, "1"), window(2, 11, "1"), window(4, 13, "1")], {
      focused: 3,
    }),
  );
  assert.deepEqual(listed(), [1, 2, 3, 4]);
  // Window 2 leaves for Desktop 2, window 3 closes, and window 4's ID now belongs to
  // another launch of the same app: three removals, one arrival elsewhere.
  store.reconcile(
    snap("1", [window(1, 10, "1"), window(2, 11, "2"), window(4, 13, "1", {launched: 2})]),
  );
  assert.deepEqual(listed(), [1, 4]);
  assert.deepEqual(ids(store, "D:2"), [2]);
  // A window the list knows counts as ordinary wherever it turns up, even where
  // Accessibility cannot see it; coming back to Desktop 1 appends rather than restores.
  store.reconcile(snap("1", [window(1, 10, "1"), window(2, 11, "1", {ordinary: undefined})]));
  assert.deepEqual(listed(), [1, 2]);
  assert.equal(store.entries.has("D:2"), false);
  // Fullscreen moves the window to a fullscreen Space and back to whichever Desktop macOS picks.
  store.reconcile(snap("1", [window(1, 10, "9"), window(2, 11, "1")], {fullscreen: ["9"]}));
  assert.deepEqual(listed(), [2]);
  store.reconcile(snap("1", [window(1, 10, "2"), window(2, 11, "1")]));
  assert.deepEqual([listed(), ids(store, "D:2")], [[2], [1]]);
  // A deleted Desktop takes its list with it; an emptied one is dropped.
  store.reconcile({...snap("1", [window(2, 11, "1")]), displays: []});
  assert.equal(store.entries.size, 0);
});

test("a window on every Desktop holds an independent position in each list", () => {
  const store = new WindowLists();
  const everywhere = (id: number, pid: number) => window(id, pid, "", {spaces: ["1", "2"]});
  store.reconcile(snap("1", [window(1, 10, "1"), everywhere(2, 11), window(3, 12, "2")]));
  assert.deepEqual(
    [ids(store, "D:1"), ids(store, "D:2")],
    [
      [1, 2],
      [2, 3],
    ],
  );
  const first = store.entries.get("D:1")!;
  assert.equal(store.move(first, windowsOf(first)[1]!, {slot: 1}), true);
  assert.deepEqual(
    [ids(store, "D:1"), ids(store, "D:2")],
    [
      [2, 1],
      [2, 3],
    ],
  );
  store.reconcile(snap("2", [window(1, 10, "1"), everywhere(2, 11), window(3, 12, "2")]));
  assert.deepEqual(
    [ids(store, "D:1"), ids(store, "D:2")],
    [
      [2, 1],
      [2, 3],
    ],
  );
});

test("waiting slots keep their numbers as windows leave and arrive out of order", () => {
  const store = new WindowLists();
  const app = (id: number, pid: number, name: string) =>
    window(id, pid, "1", {app: name, bundleID: name});
  const list = store.prepare(snap("1", []));
  store.seed(
    list,
    ["a", "b", "c"].map((name) => ({bundleID: name, app: name})),
  );
  const order = () => list.slots.map((s) => (isWindow(s) ? s.id : s.app));
  // The last app arrives first and keeps slot 3; a stranger appends after the named slots.
  store.reconcile(snap("1", [app(3, 30, "c"), app(9, 90, "x")]));
  assert.deepEqual(order(), ["a", "b", 3, 9]);
  // Slot 1 arrives, then leaves again: the waiting slot behind it moves up.
  store.reconcile(snap("1", [app(1, 10, "a"), app(3, 30, "c"), app(9, 90, "x")]));
  assert.deepEqual(order(), [1, "b", 3, 9]);
  store.reconcile(snap("1", [app(3, 30, "c"), app(9, 90, "x")]));
  assert.deepEqual(order(), ["b", 3, 9]);
  store.reconcile(snap("1", [app(2, 20, "b"), app(3, 30, "c"), app(9, 90, "x")]));
  assert.deepEqual(order(), [2, 3, 9]);
  // Giving up closes the gap, and a list with nothing left is forgotten.
  store.seed(list, [{bundleID: "d", app: "d"}]);
  assert.deepEqual(order(), ["d", 2, 3, 9]);
  assert.deepEqual(store.expire(list), ["d"]);
  assert.deepEqual(order(), [2, 3, 9]);
  store.reconcile(snap("1", []));
  assert.equal(store.entries.size, 0);
  const occupied = snap("1", [app(1, 10, "a")]);
  store.reconcile(occupied);
  assert.throws(() => store.prepare(occupied), /empty Desktop/);
});

test("a preset numbers its apps first, reusing listed hidden windows, and leaves the rest after", () => {
  const store = new WindowLists();
  const hidden = (id: number, pid: number, name: string) =>
    window(id, pid, "1", {app: name, bundleID: name, onScreen: false});
  store.reconcile(snap("1", [hidden(1, 10, "x"), hidden(2, 20, "b"), hidden(3, 30, "b")]));
  const list = store.prepare(snap("1", []));
  store.seed(list, [
    {bundleID: "a", app: "a"},
    {bundleID: "b", app: "b"},
  ]);
  assert.deepEqual(
    list.slots.map((s) => (isWindow(s) ? s.id : s.app)),
    ["a", 2, 1, 3],
  );
  assert.throws(() => store.prepare(snap("1", [])), /already waiting/);
});

test("moving a window keeps the others in order, stops at the edges, and rejects bad targets", () => {
  const cases: [string, string, MoveTarget, string][] = [
    ["ABCD", "D", {slot: 1}, "DABC"],
    ["ABCD", "B", {slot: 4}, "ACDB"],
    ["ABCD", "C", -1, "ACBD"],
    ["ABCDE", "B", {slot: 7}, "ACDEB"],
    ["ABCD", "B", -20, "BACD"],
    ["ABCD", "A", -1, "ABCD"],
    ["ABCD", "B", 0, "ABCD"],
    ["A", "A", {slot: 5}, "A"],
    ["ABCDEFGHIJKL", "A", 30, "BCDEFGHIJKLA"],
  ];
  const store = new WindowLists();
  for (const [start, title, target, expected] of cases) {
    const windows = [...start].map((letter, i) => ({
      ...window(i + 1, 10, "1"),
      title: letter,
      visible: true,
    }));
    const list = {display: "D", space: "1", slots: [...windows]},
      moved = windows.find((w) => w.title === title)!,
      label = JSON.stringify([start, title, target]);
    assert.equal(store.move(list, moved, target), start !== expected, label);
    assert.equal(
      windowsOf(list)
        .map((w) => w.title)
        .join(""),
      expected,
      label,
    );
  }
  const list = {display: "D", space: "1", slots: []};
  assert.equal(store.move(list, {...window(3, 10, "1"), visible: true}, -1), false);
  for (const bad of [
    1.5,
    Number.NaN,
    Number.POSITIVE_INFINITY,
    "1",
    null,
    undefined,
    {slot: 0},
    {slot: -1},
    {slot: 1.5},
    {slot: "1"},
    {slot: 1, extra: 1},
    {},
    Object.assign([], {slot: 2}),
  ])
    assert.throws(() => moveTarget(bad), /move target/, JSON.stringify(bad));
  assert.deepEqual([moveTarget(-3), moveTarget(0), moveTarget({slot: 2})], [-3, 0, {slot: 2}]);
});

test("startup failure cleans partially installed bindings", async () => {
  const {hs, state} = fakeHS();
  state.failBinding = "[";
  const app = session(hs);
  await assert.rejects(app.start(options), /Shortcut unavailable/);
  assert.equal(app.status().state, "Stopped");
  assert.ok(state.keys.every((k) => k.destroyed));
  assert.equal(state.tasks[0]!.isRunning, false);
});

test("stop and start preserve configuration and release all owned resources", async () => {
  const {hs, state} = fakeHS();
  const app = session(hs);
  await app.start({...options, bindings: {"desktop-create": "ctrl-option-n"}});
  assert.equal(app.status().state, "Running");
  app.stop();
  assert.ok(state.keys.every((k) => k.destroyed));
  assert.ok(state.timers.every((t) => t.stopped));
  await app.start();
  assert.ok(state.keys.some((k) => k.enabled && k.key === "n"));
  assert.equal(state.notificationRequests, 1);
  app.stop();
  assert.ok(state.tasks.every((t) => !t.isRunning));
});

test("cancelling startup cannot register shortcuts or stop a later session", async () => {
  const {hs, state} = fakeHS();
  state.replies = false;
  const app = session(hs),
    pending = app.start(options);
  const rejected = assert.rejects(pending, /stopped/);
  app.stop();
  await rejected;
  assert.equal(state.keys.length, 0);
  state.replies = true;
  await app.start(options);
  state.tasks[0]!.ended(1, "old session");
  assert.equal(app.status().state, "Running");
  app.stop();
});

test("Quick Apps resolve absolute references through the API and toggle in JavaScript", async () => {
  const {hs, state} = fakeHS();
  const mac = new FakeWorkspace();
  const app = session(hs, {workspace: () => mac}),
    reference = "/tmp/Fixture.app";
  await app.start({
    overlay: false,
    quickApps: [{app: reference, shortcut: "cmd-shift-j", size: {width: 700, height: 500}}],
  });
  const request = state.requests.find((r) => r.command === "application.resolve");
  assert.equal(request!.app, reference);
  assert.deepEqual(app.status().quickApps, [
    {app: reference, bundleID: "app." + reference, shortcut: "cmd-shift-j"},
  ]);
  const shown = await app.quickApp(reference);
  assert.equal("action" in shown && shown.action, "shown");
  assert.deepEqual(mac.launches, ["app." + reference]);
  assert.equal(mac.frame(200)!.w, 700);
  assert.equal(mac.frame(200)!.h, 500);
  app.stop();
});

test("Accessibility setup opens settings and resumes without reload or notifications", async () => {
  const {hs, state} = fakeHS();
  state.trusted = false;
  const app = session(hs);
  const pending = app.start(options);
  assert.equal(app.start(), pending);
  assert.equal(app.status().state, "Waiting for Accessibility");
  assert.equal(state.keys.length, 0);
  assert.equal(state.tasks.length, 0);
  assert.equal(state.notificationRequests, 0);
  assert.deepEqual(state.dialogs[0]!.labels, ["Open Settings", "Later"]);
  state.dialogs[0]!.click(0);
  assert.equal(state.accessibilityRequests, 1);
  assert.match(state.openedURLs[0]!, /Privacy_Accessibility/);
  state.trusted = true;
  state.timers.find((timer) => !timer.stopped)!.callback();
  await pending;
  assert.equal(app.status().state, "Running");
  assert.equal(state.dialogs[0]!.closed, true);
  assert.ok(state.keys.some((key) => key.enabled));
  app.stop();
});

test("permission waiting can be cancelled without a delayed startup", async () => {
  const {hs, state} = fakeHS();
  state.trusted = false;
  const app = session(hs);
  const pending = app.start(options);
  const rejected = assert.rejects(pending, /stopped/);
  state.dialogs[0]!.click(1);
  assert.equal(state.openedURLs.length, 0);
  app.stop();
  await rejected;
  assert.equal(app.status().state, "Paused");
  assert.ok(state.timers.every((timer) => timer.stopped));
  assert.equal(state.dialogs[0]!.closed, true);
  state.trusted = true;
  await app.start();
  app.stop();
});

test("host permission alone does not start shortcuts before the provider is trusted", async () => {
  const {hs, state} = fakeHS();
  state.hostTrusted = true;
  state.trusted = false;
  state.snapshot.trusted = false;
  const app = session(hs);
  const pending = app.start(options);
  // Settle the fake provider handshake without firing its deadline timers.
  for (let i = 0; i < 20; i++) await Promise.resolve();
  assert.equal(app.status().state, "Waiting for Accessibility");
  assert.equal(state.keys.length, 0);
  state.snapshot.trusted = true;
  state.timers.findLast((timer) => !timer.stopped)!.callback();
  await pending;
  assert.equal(app.status().state, "Running");
  assert.equal(state.tasks.length, 1);
  app.stop();
});

test("startup errors remain in status when notifications are denied and can be retried", async () => {
  const {hs, state} = fakeHS();
  hs.notify.show = () => {
    throw new Error("denied");
  };
  state.failBinding = "[";
  const app = session(hs);
  await assert.rejects(app.start(options), /Shortcut unavailable/);
  assert.match(app.status().error ?? "", /Shortcut unavailable/);
  assert.equal(app.status().state, "Stopped");
  state.failBinding = null;
  await app.start();
  assert.equal(app.status().state, "Running");
  app.stop();
});

test("settings failure provides instructions in Console", async () => {
  const {hs, state} = fakeHS();
  state.trusted = false;
  state.openURLResult = false;
  const app = session(hs);
  const pending = app.start(options);
  const rejected = assert.rejects(pending, /stopped/);
  state.dialogs[0]!.click(0);
  assert.equal(state.openedURLs.length, 2);
  assert.equal(state.consoleOpened, true);
  app.stop();
  await rejected;
});

test("a Hammerspoon 2 build other than the pinned one warns but still starts", async () => {
  const {hs, state} = fakeHS();
  state.build = "999";
  const app = session(hs);
  await app.start(options);
  assert.equal(app.status().state, "Running");
  assert.deepEqual(app.status().hammerspoon2, {build: "999", expectedBuild: "133.1"});
  assert.ok(state.notifications.some((n) => /not the tested build/.test(n)));
  app.stop();
  state.notifications.length = 0;
  state.build = "133.1";
  await app.start();
  assert.deepEqual(state.notifications, []);
  app.stop();
});

test("windows are listed at start, selection focuses exact windows, and watchers follow them", async () => {
  const {hs, state} = fakeHS();
  const fake = fakeApp(hs, state, [1, 2]);
  const app = session(hs);
  await app.start(options);
  assert.equal(app.status().windows.lists, 1);
  assert.equal(state.watched.length, 1);
  assert.notEqual(state.watched[0]![0], fake.application);
  assert.ok((state.watched[0]![1] as string[]).includes("AXWindowCreated"));
  assert.ok((state.watched[0]![1] as string[]).includes("AXFocusedWindowChanged"));
  assert.ok(!(state.watched[0]![1] as string[]).includes("AXWindowResized"));
  assert.deepEqual(await app.windows.select(2), {window: 2});
  assert.equal(state.snapshot.focused, 2);
  assert.deepEqual(await app.windows.select(2), {window: 2});
  // Selection never reorders: window 1 is still first.
  assert.deepEqual(await app.windows.select(1), {window: 1});
  app.stop();
  assert.deepEqual(state.removedWatchers, state.watched);
});

test("selecting a hidden or minimized window reveals that window and keeps its number", async () => {
  const {hs, state} = fakeHS();
  const fake = fakeApp(hs, state, [1, 2, 3]);
  const app = session(hs);
  await app.start(options);
  fake.windows[1]!.isMinimized = true;
  Object.assign(state.snapshot.windows[1]!, {onScreen: false});
  fake.application.isHidden = true;
  Object.assign(state.snapshot.windows[2]!, {onScreen: false});
  assert.deepEqual(await app.windows.select(2), {window: 2});
  assert.deepEqual([fake.windows[1]!.unminimized, fake.application.unhidden], [1, 1]);
  assert.equal(fake.windows[1]!.isMinimized, false);
  assert.deepEqual(await app.windows.select(3), {window: 3});
  assert.deepEqual(await app.windows.select(1), {window: 1});
  assert.equal(fake.windows[1]!.unminimized, 1);
  // Nothing asked the provider for anything but the census, and no frame changed.
  assert.ok(state.requests.slice(1).every((r) => r.command === "spaces.snapshot"));
  assert.deepEqual(
    fake.windows.map((w) => w.frame.w),
    [400, 400, 400],
  );
  app.stop();
});

test("cycling wraps and starts at either end when nothing listed is focused", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2, 3]);
  const app = session(hs);
  await app.start(options);
  assert.deepEqual(await app.windows.cycle(1), {window: 2});
  assert.deepEqual(await app.windows.cycle(1), {window: 3});
  assert.deepEqual(await app.windows.cycle(1), {window: 1});
  assert.deepEqual(await app.windows.cycle(-1), {window: 3});
  state.snapshot.focused = 77;
  assert.deepEqual(await app.windows.cycle(1), {window: 1});
  state.snapshot.focused = 77;
  assert.deepEqual(await app.windows.cycle(-1), {window: 3});
  assert.deepEqual(await app.windows.cycle(-5), {window: 1});
  app.stop();
});

test("unused numbers, empty lists, and fullscreen Spaces do nothing", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2]);
  const app = session(hs);
  await app.start(options);
  assert.deepEqual(await app.windows.select(3), {noop: true});
  assert.deepEqual(await app.windows.select(10), {noop: true});
  state.snapshot.displays[0]!.spaces.push({id: "9", fullscreen: true});
  state.snapshot.displays[0]!.current = state.snapshot.focusedSpace = "9";
  assert.deepEqual(await app.windows.select(1), {noop: true});
  assert.deepEqual(await app.windows.cycle(1), {noop: true});
  assert.deepEqual(await app.windows.move(1), {noop: true});
  state.snapshot.displays[0]!.current = state.snapshot.focusedSpace = "1";
  state.snapshot.windows = [];
  assert.deepEqual(await app.windows.select(1), {noop: true});
  assert.deepEqual(await app.windows.cycle(1), {noop: true});
  assert.equal(app.status().windows.lists, 0);
  app.stop();
});

test("commands follow the Desktop macOS calls focused, not the target display", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2, 3]);
  state.snapshot.displays = [
    {id: "Main", current: "1", spaces: [{id: "1", fullscreen: false}]},
    {id: "B", current: "2", spaces: [{id: "2", fullscreen: false}]},
  ];
  state.snapshot.windows[2]!.spaces = ["2"];
  state.snapshot.focusedSpace = "2";
  const app = session(hs);
  await app.start(options);
  assert.equal(app.status().windows.lists, 2);
  assert.deepEqual(await app.windows.select(1), {window: 3});
  assert.deepEqual(await app.windows.select(2), {noop: true});
  state.snapshot.focusedSpace = "1";
  assert.deepEqual(await app.windows.select(2), {window: 2});
  app.stop();
});

test("a dialog that keeps focus is respected, and a window that will not focus is reported", async () => {
  const {hs, state} = fakeHS();
  const fake = fakeApp(hs, state, [1, 2]);
  const app = session(hs);
  await app.start(options);
  // A dialog of the app in front before the request is not the requested window.
  state.snapshot.focused = -1;
  fake.dialogs.add(2);
  assert.deepEqual(await app.windows.select(2), {window: 2});
  assert.equal(state.snapshot.focused, -2);
  fake.dialogs.clear();
  state.snapshot.focused = 2;
  fake.focusWorks = false;
  await assert.rejects(pumped(state, app.windows.select(1)), /Could not focus the window/);
  assert.ok(state.notifications.some((n) => /Could not focus/.test(n)));
  // The failure changed nothing: the list and its order are intact.
  fake.focusWorks = true;
  state.snapshot.focused = 0;
  assert.deepEqual(await app.windows.select(1), {window: 1});
  state.snapshot.windows = [];
  assert.deepEqual(await app.windows.select(1), {noop: true});
  app.stop();
});

test("a stale selection target that closed is reported without renumbering the rest", async () => {
  const {hs, state} = fakeHS();
  const fake = fakeApp(hs, state, [1, 2, 3]);
  const app = session(hs);
  await app.start(options);
  // The census still lists window 2 but the app no longer has it.
  fake.windows.splice(1, 1);
  await assert.rejects(app.windows.select(2), /selected window closed/);
  assert.deepEqual(await app.windows.select(3), {window: 3});
  app.stop();
});

test("overlapping Space actions are dropped and stop cannot reenable old bindings", async () => {
  const {hs, state} = fakeHS(),
    app = session(hs);
  await app.start(options);
  state.replies = false;
  const first = app.space("create"),
    rejected = assert.rejects(first, /stopped/);
  assert.deepEqual(await app.space("delete"), {busy: true});
  app.stop();
  await rejected;
  assert.equal(state.requests.filter((r) => r.command === "spaces.delete").length, 0);
  assert.ok(state.keys.every((k) => !k.enabled));
});

test("stop and defaults failures preserve independent HS2 scripts", async () => {
  for (const failure of [null, "options", "permission", "shortcut", "providers"]) {
    const {hs, state} = fakeHS();
    const independent = hs.hotkey.create(["ctrl"], "z", () => {}, null, null)!;
    independent.enable();
    const timer = hs.timer.doEvery(1, () => {}) as unknown as {stopped: boolean};
    const app = session(hs);
    if (failure === "permission") state.trusted = false;
    if (failure === "shortcut") state.failBinding = "[";
    if (failure === "permission") {
      const pending = app.start(options);
      const rejected = assert.rejects(pending, /stopped/);
      app.stop();
      await rejected;
    } else if (["options", "shortcut"].includes(failure ?? "")) {
      await assert.rejects(app.start(failure === "options" ? {unknown: true} : options));
    } else {
      await app.start(options);
      if (failure === "providers") {
        state.tasks[0]!.ended(9, "crash");
        assert.equal(app.status().state, "Stopped", failure);
        assert.match(app.status().error ?? "", /exited/, failure);
      } else app.stop();
    }
    assert.equal(
      independent.isEnabled
        ? independent.isEnabled()
        : (independent as unknown as {enabled: boolean}).enabled,
      true,
      failure ?? "none",
    );
    assert.equal(
      (independent as unknown as {destroyed: boolean}).destroyed,
      false,
      failure ?? "none",
    );
    assert.equal(timer.stopped, false, failure ?? "none");
  }
});

test("moving the focused window changes only the order and leaves focus and Spaces alone", async () => {
  const {hs, state} = fakeHS();
  const fake = fakeApp(hs, state, [1, 2, 3, 4]);
  const app = session(hs);
  await app.start(options);
  const requests = state.requests.length;
  assert.deepEqual(await app.windows.move({slot: 4}), {window: 1});
  assert.deepEqual(await app.windows.move(-2), {window: 1});
  assert.ok(state.requests.slice(requests).every((r) => r.command === "spaces.snapshot"));
  assert.equal(state.snapshot.focused, 1);
  assert.deepEqual(
    fake.windows.map((w) => w.frame.w),
    [400, 400, 400, 400],
  );
  // The order is 2, 1, 3, 4.
  assert.deepEqual(await app.windows.select(2), {window: 1});
  assert.deepEqual(await app.windows.select(1), {window: 2});
  // The shortcut moves once per press.
  const moveKeys = state.keys.filter((k) => k.mods.includes("shift"));
  assert.equal(moveKeys.length, 12);
  assert.ok(moveKeys.every((k) => k.repeat === null));
  const moves = () => app.status().metrics.filter((m) => m.name === "move").length;
  const before = moves();
  moveKeys.find((k) => k.key === "]")!.callback();
  for (let i = 0; i < 100 && moves() === before; i++) await Promise.resolve();
  assert.equal(moves(), before + 1);
  assert.deepEqual(await app.windows.select(2), {window: 2});
  app.stop();
});

test("a move needs a focused listed window, valid arguments, and a free session", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2, 3]);
  const third = state.snapshot.windows.pop()!;
  const app = session(hs);
  await app.start(options);
  state.snapshot.focused = 77;
  assert.deepEqual(await app.windows.move(1), {noop: true});
  // A window that arrived since the last census is listed at once.
  state.snapshot.windows.push(third);
  state.snapshot.focused = 3;
  assert.deepEqual(await app.windows.move({slot: 1}), {window: 3});
  await assert.rejects(app.windows.move(1.5), /move target/);
  await assert.rejects(app.windows.move({slot: 0}), /move target/);
  // A move during another action is dropped; a cancelled census leaves the order alone.
  state.replies = false;
  const pending = app.windows.move({slot: 3}),
    rejected = assert.rejects(pending, /stopped/);
  assert.deepEqual(await app.windows.move(1), {busy: true});
  app.stop();
  await rejected;
  assert.deepEqual(
    parse(state.files[path]!)![0]!.windows.map((w) => w.id),
    [3, 1, 2],
  );
});

test("presets are validated before anything starts", () => {
  const preset = (extra: Partial<PresetOption> & Record<string, unknown> = {}) => ({
    name: "Dev",
    apps: ["Ghostty", "Linear"],
    ...extra,
  });
  const cases: [unknown, RegExp][] = [
    [{presets: {}}, /presets must be an array/],
    [{presets: Array(51).fill(preset())}, /at most 50/],
    [{presets: [preset({name: " "})]}, /Preset 1 needs a name/],
    [{presets: [preset(), preset()]}, /"Dev" is listed twice/],
    [{presets: [preset({apps: []})]}, /"Dev" needs a list of app names/],
    [{presets: [preset({apps: "Ghostty"})]}, /"Dev" needs a list of app names/],
    [{presets: [preset({apps: ["Ghostty", " Ghostty"]})]}, /"Dev" lists Ghostty twice/],
    [{presets: [preset({apps: ["Calculator"]})]}, /"Dev" lists the Quick App Calculator/],
    [{presets: [preset({size: 1})]}, /Unknown Preset "Dev" option: size/],
    [{presets: [preset({shortcut: "cmd-option-1"})]}, /"Dev" conflicts with select-1/],
    [{presets: [preset({shortcut: "cmd-shift-c"})]}, /"Dev" conflicts with Calculator/],
    [
      {presets: [preset({shortcut: "cmd-option-d"}), preset({name: "Two", shortcut: "cmd-alt-d"})]},
      /"Two" conflicts with Preset "Dev"/,
    ],
    [{presets: [preset({shortcut: "cmd-option-p"})]}, /conflicts with presets/],
    [{presets: [preset({shortcut: "nope"})]}, /Invalid shortcut/],
    [{windows: false, presets: [preset({name: ""})]}, /needs a name/],
    [{groupPresets: [preset()]}, /Unknown Atelier option: groupPresets/],
  ];
  for (const [given, message] of cases)
    assert.throws(() => normalize(given), message, JSON.stringify(given));
  const config = normalize({
    presets: [preset({shortcut: "cmd-option-d"}), preset({name: "Writing"})],
  });
  assert.deepEqual(config.presets[0], {
    name: "Dev",
    apps: ["Ghostty", "Linear"],
    shortcut: {text: "cmd-option-d", mods: ["cmd", "alt"], key: "d", identity: "alt+cmd:d"},
  });
  assert.deepEqual(config.presets[1], {name: "Writing", apps: ["Ghostty", "Linear"]});
  const picker = config.shortcuts.find((b) => b.name === "presets")!;
  assert.deepEqual([picker.mods, picker.key], [["cmd", "alt"], "p"]);
  assert.equal(
    normalize({bindings: {presets: "none"}}).shortcuts.some((b) => b.name === "presets"),
    false,
  );
  assert.deepEqual(normalize({windows: false}).presets, []);
});

/** A Desktop over a fake Mac; the census lists its windows, hidden and minimized included. */
function presetSession(presets: PresetOption[]) {
  const {hs, state} = fakeHS();
  const mac = new FakeWorkspace();
  mac.apps.clear();
  mac.wins.clear();
  mac.front = null;
  mac.focused = 0;
  // Launched apps show a window only when the test places one.
  mac.launchedWindowFrame = null;
  fakeMac(hs, state, mac);
  Object.defineProperty(state.snapshot, "windows", {
    get: () => {
      const windows: WindowInfo[] = [];
      for (const [pid, app] of mac.apps) {
        for (const id of app.windows) {
          const win = mac.wins.get(id);
          if (!win) continue;
          windows.push(
            inventoried(id, pid, {
              app: app.bundleID.slice(4),
              bundleID: app.bundleID,
              spaces: [...win.spaces],
              onScreen: !app.hidden && !win.minimized && win.spaces.includes(mac.current),
              ordinary: !app.panel,
            }),
          );
        }
      }
      return windows;
    },
  });
  const app = session(hs, {workspace: () => mac});
  return {
    state,
    mac,
    app,
    /** A running app with one window whose ID is ten times the PID. */
    place(
      pid: number,
      name: string,
      where: {hidden?: boolean; minimized?: boolean; space?: string; panel?: boolean} = {},
    ) {
      mac.apps.set(pid, {
        bundleID: "app." + name,
        hidden: where.hidden ?? false,
        windows: [pid * 10],
        ...(where.panel ? {panel: true} : {}),
      });
      mac.wins.set(pid * 10, {
        frame: {x: 0, y: 0, w: 400, h: 300},
        minimized: where.minimized ?? false,
        spaces: [where.space ?? "1"],
      });
    },
    start: () => app.start({...options, presets}),
    timer: () => state.timers.find((t) => !t.stopped && !t.repeats && t.seconds === waitingSeconds),
  };
}

test("applying a preset reveals, launches, or skips each app and numbers them in declared order", async () => {
  const f = presetSession([
    {name: "Dev", shortcut: "cmd-option-d", apps: ["Fresh", "Hidden", "Elsewhere", "Minimized"]},
  ]);
  f.place(30, "Hidden", {hidden: true});
  f.place(31, "Elsewhere", {space: "2"});
  f.place(32, "Minimized", {minimized: true});
  await f.start();
  // Hidden and minimized windows are listed already; they do not occupy the Desktop.
  assert.equal(f.app.status().windows.lists, 1);
  const result = await f.app.preset("Dev");
  assert.deepEqual(result, {skipped: ["Elsewhere"]});
  assert.deepEqual(f.mac.launches, ["app.Fresh"]);
  assert.equal(f.mac.apps.get(30)!.hidden, false);
  assert.equal(f.mac.wins.get(320)!.minimized, false);
  // Nothing was activated: slot 1 is still waiting, and the app elsewhere was left alone.
  assert.equal(f.mac.front, null);
  assert.equal(f.state.snapshot.focused, 0);
  assert.deepEqual(await f.app.windows.select(1), {noop: true});
  assert.deepEqual(await f.app.windows.select(2), {window: 300});
  // The launched window takes slot 1 when it appears; later windows append after the named slots.
  f.place(20, "Fresh");
  assert.deepEqual(await f.app.windows.select(1), {window: 200});
  f.place(40, "Later");
  assert.deepEqual(await f.app.windows.select(3), {window: 320});
  assert.deepEqual(await f.app.windows.select(4), {window: 400});
  f.timer()!.callback();
  assert.deepEqual(await f.app.windows.select(1), {window: 200});
  f.app.stop();
});

test("a preset refuses a non-empty, fullscreen, or already waiting Desktop and changes nothing", async () => {
  const f = presetSession([{name: "Dev", apps: ["Fresh"]}]);
  f.place(30, "Open");
  await f.start();
  await assert.rejects(f.app.preset("Dev"), /empty Desktop/);
  assert.ok(f.state.notifications.some((n) => /empty Desktop/.test(n)));
  f.mac.apps.delete(30);
  const ordinary = f.state.snapshot.displays[0]!;
  f.state.snapshot.displays = [
    {
      id: "Main",
      current: "9",
      spaces: [
        {id: "1", fullscreen: false},
        {id: "9", fullscreen: true},
      ],
    },
  ];
  f.state.snapshot.focusedSpace = "9";
  await assert.rejects(f.app.preset("Dev"), /ordinary Desktop/);
  assert.deepEqual(f.mac.launches, []);
  assert.equal(f.app.status().windows.lists, 0);
  f.state.snapshot.displays = [ordinary];
  f.state.snapshot.focusedSpace = "1";
  await f.app.preset("Dev");
  await assert.rejects(f.app.preset("Dev"), /already waiting/);
  assert.deepEqual(f.mac.launches, ["app.Fresh"]);
  await assert.rejects(f.app.preset("Nope"), /not configured/);
  f.app.stop();
});

test("waiting slots close ranks after a failed launch or the timeout", async () => {
  const f = presetSession([{name: "Dev", apps: ["Broken", "Slow", "Quick"]}]);
  f.mac.launchFailures.add("app.Broken");
  await f.start();
  const result = await f.app.preset("Dev");
  assert.deepEqual("skipped" in result && result.skipped, ["Broken"]);
  assert.deepEqual(f.mac.launches, ["app.Slow", "app.Quick"]);
  // Quick keeps slot 2 while Slow is still expected in slot 1.
  f.place(21, "Quick");
  assert.deepEqual(await f.app.windows.select(1), {noop: true});
  assert.deepEqual(await f.app.windows.select(2), {window: 210});
  f.timer()!.callback();
  assert.deepEqual(await f.app.windows.select(1), {window: 210});
  f.place(20, "Slow");
  assert.deepEqual(await f.app.windows.select(2), {window: 200});
  f.app.stop();
  const g = presetSession([{name: "Solo", apps: ["Fresh"]}]);
  await g.start();
  await g.app.preset("Solo");
  assert.equal(g.app.status().windows.lists, 1);
  assert.equal(g.state.watched.length, 0);
  g.timer()!.callback();
  assert.equal(g.app.status().windows.lists, 0);
  g.place(20, "Fresh");
  assert.deepEqual(await g.app.windows.select(1), {window: 200});
  g.app.stop();
});

test("presets fill the picker and their shortcuts, skip missing apps, and stay off with window lists", async () => {
  const {hs, state} = fakeHS();
  const mac = new FakeWorkspace();
  state.missingApps = ["Ghost"];
  const app = session(hs, {workspace: () => mac});
  await app.start({
    ...options,
    presets: [
      {name: "Dev", shortcut: "cmd-option-d", apps: ["Ghost", "Fresh"]},
      {name: "Writing", apps: ["Obsidian", "Safari"]},
    ],
  });
  assert.match(app.status().error ?? "", /Preset "Dev": No application named Ghost/);
  assert.deepEqual(app.status().presets, [
    {name: "Dev", apps: ["Fresh"], shortcut: "cmd-option-d"},
    {name: "Writing", apps: ["Obsidian", "Safari"], shortcut: null},
  ]);
  const chooser = state.choosers[0]!;
  assert.deepEqual(chooser.choices, [
    {text: "Dev", subText: "Fresh"},
    {text: "Writing", subText: "Obsidian, Safari"},
  ]);
  const key = (name: string) => state.keys.find((k) => k.key === name && k.enabled);
  assert.deepEqual(key("p")!.mods, ["cmd", "alt"]);
  assert.deepEqual(key("d")!.mods, ["cmd", "alt"]);
  key("p")!.callback();
  for (let i = 0; i < 5; i++) await Promise.resolve();
  assert.equal(chooser.isVisible, true);
  const applied = () => app.status().metrics.filter((m) => m.name === "preset").length;
  chooser.onSelect!({text: "Dev"});
  for (let i = 0; i < 100 && applied() === 0; i++) await Promise.resolve();
  assert.equal(applied(), 1);
  assert.deepEqual(mac.launches, ["app.Fresh"]);
  app.stop();
  for (const extra of [{}, {windows: false}]) {
    const {hs: other, state: otherState} = fakeHS();
    const bare = session(other, {workspace: () => new FakeWorkspace()});
    await bare.start({
      ...options,
      ...extra,
      presets: "windows" in extra ? [{name: "Dev", shortcut: "cmd-option-d", apps: ["Fresh"]}] : [],
    });
    assert.equal(otherState.choosers.length, 0, JSON.stringify(extra));
    assert.ok(!otherState.keys.some((k) => ["p", "d"].includes(k.key)), JSON.stringify(extra));
    bare.stop();
  }
});

test("a revealed slot 1 takes focus; a launched one never does", async () => {
  const revealed = presetSession([{name: "Dev", apps: ["Hidden", "Fresh"]}]);
  revealed.place(30, "Hidden", {hidden: true});
  await revealed.start();
  await revealed.app.preset("Dev");
  assert.equal(revealed.state.snapshot.focused, 300);
  assert.equal(revealed.mac.front, 30);
  revealed.app.stop();
  // The launched app shows its window before the apply finishes.
  const launched = presetSession([{name: "Dev", apps: ["Fresh", "Hidden"]}]);
  launched.place(30, "Hidden", {hidden: true});
  launched.mac.launchedWindowFrame = {x: 0, y: 0, w: 400, h: 300};
  await launched.start();
  assert.deepEqual(await launched.app.preset("Dev"), {skipped: []});
  assert.deepEqual(await launched.app.windows.select(1), {window: 200});
  assert.deepEqual(await launched.app.windows.select(2), {window: 300});
  launched.state.snapshot.focused = 0;
  launched.app.stop();
});

test("an app listed under two names, or shared with a Quick App, stops startup", async () => {
  for (const [presets, quickApps, message] of [
    [[{name: "Dev", apps: ["Fresh", "com.fresh"]}], [], /"Dev" lists com.fresh twice/],
    [
      [{name: "Dev", apps: ["com.calc"]}],
      [{app: "Calculator", shortcut: "cmd-shift-c"}],
      /"Dev" lists the Quick App com.calc/,
    ],
  ] as const) {
    const {hs, state} = fakeHS();
    state.aliases = {"com.fresh": "Fresh", "com.calc": "Calculator"};
    const app = session(hs, {workspace: () => new FakeWorkspace()});
    await assert.rejects(
      app.start({...options, quickApps: [...quickApps], presets: [...presets]}),
      message,
    );
    assert.equal(app.status().state, "Stopped");
    assert.equal(state.keys.length, 0);
  }
});

test("Quick App windows are never listed, and starting with lists disabled drops them", async () => {
  const f = presetSession([{name: "Solo", apps: ["Fresh"]}]);
  f.place(30, "Calculator");
  f.state.aliases = {};
  await f.app.start({overlay: false, quickApps: [{app: "Calculator", shortcut: "cmd-shift-c"}]});
  assert.equal(f.app.status().windows.lists, 0);
  f.place(31, "Other");
  assert.deepEqual(await f.app.windows.select(1), {window: 310});
  f.app.stop();
  await f.app.start({...options, windows: false});
  assert.equal(f.app.status().windows.lists, 0);
  assert.deepEqual(
    f.state.timers.filter((t) => t.repeats && !t.stopped),
    [],
  );
  f.app.stop();
});

test("an incomplete census leaves the lists as they were", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2]);
  const app = session(hs);
  await app.start(options);
  const windows = state.snapshot.windows;
  state.snapshot.windows = [];
  state.snapshot.complete = false;
  assert.deepEqual(await app.windows.select(2), {window: 2});
  assert.equal(app.status().windows.lists, 1);
  state.snapshot.windows = windows;
  state.snapshot.complete = true;
  state.snapshot.windows.pop();
  assert.deepEqual(await app.windows.select(2), {noop: true});
  app.stop();
});

test("an incomplete census at start-up neither restores nor overwrites the saved lists", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2]);
  const text = JSON.stringify({
    version: 1,
    desktops: [
      {
        display: "Main",
        space: "1",
        windows: [
          {pid: 42, id: 2, launched: 1, app: "fixture", bundleID: "fixture"},
          {pid: 42, id: 1, launched: 1, app: "fixture", bundleID: "fixture"},
        ],
      },
    ],
  });
  state.files[path] = text;
  state.snapshot.complete = false;
  state.snapshot.windows = [];
  const app = session(hs);
  await app.start(options);
  assert.deepEqual(app.status().windows, {
    lists: 0,
    file: {path, savedAt: null, restored: null, dropped: null},
  });
  assert.deepEqual(await app.windows.select(1), {noop: true});
  assert.equal(state.files[path], text);
  // The first complete census restores the saved order.
  fakeApp(hs, state, [1, 2]);
  state.snapshot.complete = true;
  assert.deepEqual(await app.windows.select(1), {window: 2});
  assert.equal(app.status().windows.file.restored, 1);
  app.stop();
  assert.equal(state.files[path], text);
});

test("presets need window lists and a complete census, and an app with only a panel is reopened", async () => {
  const f = presetSession([{name: "Dev", apps: ["Panel", "Unknown"]}]);
  f.place(30, "Panel", {panel: true});
  f.place(31, "Unknown", {hidden: true});
  f.mac.wins.get(310)!.spaces = [];
  await f.start();
  assert.deepEqual(await f.app.preset("Dev"), {skipped: ["Unknown"]});
  assert.deepEqual(f.mac.launches, ["app.Panel"]);
  assert.equal(f.mac.apps.get(31)!.hidden, true);
  f.timer()!.callback();
  f.app.stop();
  await f.app.start({...options, windows: false, presets: [{name: "Dev", apps: ["Panel"]}]});
  await assert.rejects(f.app.preset("Dev"), /windows: true/);
  f.app.stop();
  await f.start();
  f.state.snapshot.complete = false;
  await assert.rejects(f.app.preset("Dev"), /Could not read the windows/);
  f.app.stop();
});
