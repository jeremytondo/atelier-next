import assert from "node:assert/strict";
import {test} from "node:test";
import type {HS} from "../api/hs.ts";
import {createAPI} from "../api/index.ts";
import type {Snapshot, WindowInfo} from "../api/spaces.ts";
import {createDefaults} from "../defaults/index.ts";
import {
  debounceSeconds,
  parse,
  type SavedDesktop,
  StateFile,
  stateVersion,
} from "../defaults/state.ts";
import {WindowLists, windowsOf} from "../defaults/windows.ts";
import {type FakeState, fakeApp, fakeHS, inventoried} from "./fakes.ts";

const path = "/Users/fake/Library/Application Support/Atelier/windows.json";
const options = {overlay: false, quickApps: []};
const window = (
  id: number,
  pid: number,
  space: string,
  extra: Partial<WindowInfo> = {},
): WindowInfo => ({
  ...inventoried(id, pid, {app: "app.a", bundleID: "app.a", spaces: [space]}),
  ...extra,
});
const snapshot = (current: string, windows: WindowInfo[], spaces = ["1", "2"]): Snapshot => ({
  trusted: true,
  focused: windows[0]?.id ?? 0,
  focusedSpace: current,
  targetDisplay: "D",
  missionControl: false,
  displays: [{id: "D", current, spaces: spaces.map((id) => ({id, fullscreen: false}))}],
  windows,
  complete: true,
});
const saved = (space: string, ...windows: [number, number, string?][]): SavedDesktop => ({
  display: "D",
  space,
  windows: windows.map(([pid, id, bundleID = "app.a"]) => ({
    pid,
    id,
    launched: 1,
    app: bundleID,
    bundleID,
  })),
});
const fileText = (desktops: SavedDesktop[]) => JSON.stringify({version: stateVersion, desktops});
const savedIDs = (state: FakeState) => parse(state.files[path]!)![0]!.windows.map((w) => w.id);
const debounce = (state: FakeState) =>
  state.timers.find((t) => !t.stopped && !t.repeats && t.seconds === debounceSeconds);
function session(hs: HS) {
  const api = createAPI(hs, {providers: "/share/atelier/atelier-providers"});
  return createDefaults(hs, api, {expectedBuild: "133.1", version: "test"});
}
function capture(run: () => Promise<void> | void): Promise<string[]> {
  const lines: string[] = [],
    original = console.log;
  console.log = (line: string) => lines.push(line);
  return Promise.resolve()
    .then(run)
    .finally(() => {
      console.log = original;
    })
    .then(() => lines);
}
test("parse accepts the file shape and rejects anything else", () => {
  const desktops = [saved("1", [10, 100], [11, 101])];
  assert.deepEqual(parse(fileText(desktops)), desktops);
  for (const text of [
    "{",
    "[]",
    "null",
    JSON.stringify({version: 2, desktops: []}),
    JSON.stringify({version: 1, desktops: {}}),
    JSON.stringify({version: 1, groups: []}),
    JSON.stringify({version: 1, desktops: [{display: "D", windows: []}]}),
    JSON.stringify({version: 1, desktops: [{display: "D", space: "1", windows: [{pid: "x"}]}]}),
    fileText(desktops).replace('"launched":1', '"launched":"soon"'),
  ])
    assert.equal(parse(text), null, text);
});

test("serialize and restore round-trip order and identities, not titles or visibility", () => {
  const store = new WindowLists();
  const snap = snapshot("1", [
    window(100, 10, "1", {title: "One"}),
    window(101, 11, "1", {onScreen: false}),
  ]);
  store.reconcile(snap);
  const text = fileText(store.serialize());
  assert.ok(!text.includes("One") && !text.includes("visible"));
  const restored = new WindowLists();
  assert.deepEqual(restored.restore(parse(text)!, snap), {restored: 1, dropped: 0});
  assert.deepEqual(restored.serialize(), store.serialize());
  const windows = windowsOf(restored.focused(snap)!);
  assert.deepEqual(
    windows.map((w) => [w.id, w.title, w.visible]),
    [
      [100, "One", true],
      [101, "", false],
    ],
  );
});

test("restore drops lists without a live window and entries whose window is gone or reused", () => {
  const store = new WindowLists();
  const live = snapshot("1", [
    window(101, 11, "1"),
    window(102, 12, "1", {app: "app.other", bundleID: "app.other", launched: 2}),
    window(100, 10, "1"),
    window(300, 30, "1"),
    window(200, 20, "2"),
    // The same process and window IDs as a saved entry, but a later launch.
    window(103, 13, "1", {launched: 2}),
  ]);
  const result = store.restore(
    [
      saved("1", [12, 102], [10, 100], [11, 101], [13, 103], [14, 104]),
      saved("9", [10, 100]),
      saved("2", [20, 200]),
      saved("3", [21, 201]),
    ],
    live,
  );
  assert.deepEqual(result, {restored: 2, dropped: 2});
  // A window ID reused by a later launch loses its saved slot and joins as a new window.
  assert.deepEqual(
    windowsOf(store.entries.get("D:1")!).map((w) => [w.pid, w.id]),
    [
      [10, 100],
      [11, 101],
      [12, 102],
      [30, 300],
      [13, 103],
    ],
  );
  assert.deepEqual(
    windowsOf(store.entries.get("D:2")!).map((w) => w.id),
    [200],
  );
});

test("the state file debounces, skips unchanged writes, flushes on demand, and reports failure once", () => {
  const {hs, state} = fakeHS(),
    file = new StateFile(hs);
  assert.equal(file.path, path);
  assert.deepEqual(file.read(), {status: "missing"});
  file.save([saved("1", [10, 100])]);
  file.save([saved("1", [10, 100], [11, 101])]);
  assert.equal(state.files[path], undefined);
  assert.equal(state.timers.filter((t) => !t.stopped).length, 1);
  debounce(state)!.callback();
  assert.deepEqual(parse(state.files[path]!), [saved("1", [10, 100], [11, 101])]);
  assert.ok(file.savedAt);
  file.save([saved("1", [10, 100], [11, 101])]);
  assert.equal(debounce(state), undefined);
  file.save([]);
  file.flush();
  assert.deepEqual(parse(state.files[path]!), []);
  assert.ok(state.timers.every((t) => t.stopped));
  assert.deepEqual(new StateFile(hs).read(), {status: "ok", desktops: []});
  state.files[path] = "{";
  assert.deepEqual(file.read(), {status: "malformed"});
  const errors: string[] = [],
    original = console.error;
  console.error = (line: string) => errors.push(line);
  try {
    state.writable = false;
    file.save([saved("1", [10, 100])]);
    file.flush();
    file.save([saved("1", [11, 101])]);
    file.flush();
  } finally {
    console.error = original;
  }
  assert.deepEqual(errors, ["Atelier: Could not write " + path]);
});

test("lists are written on stop and before reload, and come back on the next start", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2, 3]);
  const third = state.snapshot.windows.pop()!;
  const first = session(hs);
  const lines = await capture(() => first.start(options));
  assert.deepEqual(lines, ["Atelier: No saved window lists at " + path, "Atelier: Running"]);
  assert.equal(state.files[path], undefined);
  await first.windows.select(2);
  first.stop();
  assert.deepEqual(
    parse(state.files[path]!)![0]!.windows.map((w) => [w.pid, w.id, w.launched, w.bundleID]),
    [
      [42, 1, 1, "fixture"],
      [42, 2, 1, "fixture"],
    ],
  );
  assert.ok(first.status().windows.file.savedAt);
  // The same context again, as after Reload Config or a relaunch.
  state.snapshot.windows.push(third);
  const second = session(hs);
  const restoreLines = await capture(() => second.start(options));
  assert.ok(restoreLines.includes("Atelier: Restored 1 window lists, dropped 0"));
  assert.deepEqual(second.status().windows, {
    lists: 1,
    file: {path, savedAt: null, restored: 1, dropped: 0},
  });
  assert.deepEqual(await second.windows.select(3), {window: 3});
  debounce(state)!.callback();
  assert.deepEqual(savedIDs(state), [1, 2, 3]);
  const reload = state.keys.find((k) => k.key === "r" && k.enabled)!;
  state.snapshot.windows.pop();
  await second.windows.cycle(1);
  reload.callback();
  for (let i = 0; i < 5; i++) await Promise.resolve();
  assert.equal(state.reloaded, true);
  assert.equal(second.status().state, "Paused");
  assert.deepEqual(savedIDs(state), [1, 2]);
});

test("a malformed or off-Desktop file starts clean without being overwritten by an empty start", async () => {
  const {hs, state} = fakeHS();
  state.files[path] = "not json";
  const app = session(hs);
  const lines = await capture(() => app.start(options));
  assert.ok(lines.includes("Atelier: Ignoring malformed window lists at " + path));
  assert.equal(app.status().windows.lists, 0);
  assert.deepEqual(app.status().windows.file.restored, null);
  app.stop();
  assert.deepEqual(parse(state.files[path]!), []);
  state.files[path] = fileText([saved("9", [10, 100])]);
  await app.start();
  assert.equal(app.status().windows.file.dropped, 1);
  debounce(state)?.callback();
  assert.deepEqual(parse(state.files[path]!), []);
  app.stop();
});

test("disabling window lists leaves the state file alone", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1]);
  const text = fileText([saved("1", [42, 1, "fixture"])]);
  state.files[path] = text;
  const app = session(hs);
  await app.start({...options, windows: false});
  assert.equal(app.status().windows.lists, 0);
  app.stop();
  assert.equal(state.files[path], text);
});

test("a saved list comes back only if one of its windows still exists with the same launch", () => {
  // Display, Space, process, and window IDs can all repeat after a restart.
  const store = new WindowLists();
  const live = snapshot("1", [window(300, 30, "1"), window(201, 21, "2")], ["1", "2", "3"]);
  const result = store.restore(
    [saved("1", [10, 100], [11, 101]), saved("2", [20, 200], [21, 201]), saved("3")],
    live,
  );
  assert.deepEqual(result, {restored: 1, dropped: 2});
  // Desktop 1 lost its saved list; the live window there starts a fresh one.
  assert.deepEqual(
    windowsOf(store.entries.get("D:1")!).map((w) => w.id),
    [300],
  );
  assert.deepEqual(
    windowsOf(store.entries.get("D:2")!).map((w) => w.id),
    [201],
  );
  const relaunched = new WindowLists();
  relaunched.restore([saved("1", [10, 100])], snapshot("1", [window(100, 10, "1", {launched: 9})]));
  assert.deepEqual(
    windowsOf(relaunched.entries.get("D:1")!).map((w) => w.launched),
    [9],
  );
  const reused = new WindowLists();
  reused.restore(
    [saved("1", [10, 100])],
    snapshot("1", [window(100, 10, "1", {bundleID: "app.other"})]),
  );
  assert.deepEqual(
    windowsOf(reused.entries.get("D:1")!).map((w) => w.bundleID),
    ["app.other"],
  );
});

test("a resumed session takes the file as truth, even when it is missing or broken", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2]);
  state.files[path] = fileText([{...saved("1", [42, 2, "fixture"]), display: "Main"}]);
  const app = session(hs);
  await app.start(options);
  assert.deepEqual(app.status().windows, {
    lists: 1,
    file: {path, savedAt: null, restored: 1, dropped: 0},
  });
  assert.deepEqual(await app.windows.select(1), {window: 2});
  app.stop();
  delete state.files[path];
  await app.start();
  assert.equal(app.status().windows.file.restored, null);
  app.stop();
  // A fresh list starts with the focused window first.
  assert.deepEqual(
    parse(state.files[path]!)![0]!.windows.map((w) => w.id),
    [2, 1],
  );
  state.files[path] = "{";
  await app.start();
  assert.equal(app.status().windows.file.restored, null);
  app.stop();
  assert.deepEqual(
    parse(state.files[path]!)![0]!.windows.map((w) => w.id),
    [2, 1],
  );
});

test("a reordered list saves its latest order and restores it for surviving windows", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2, 3]);
  const first = session(hs);
  await first.start(options);
  assert.deepEqual(await first.windows.move(2), {window: 1});
  assert.deepEqual(await first.windows.move(-1), {window: 1});
  assert.equal(
    state.timers.filter((t) => !t.stopped && !t.repeats && t.seconds === debounceSeconds).length,
    1,
  );
  debounce(state)!.callback();
  assert.deepEqual(savedIDs(state), [2, 1, 3]);
  assert.deepEqual(await first.windows.move({slot: 2}), {noop: true});
  assert.equal(debounce(state), undefined);
  first.stop();
  // The next context: window 3 has closed and window 4 has opened.
  fakeApp(hs, state, [1, 2, 3, 4]);
  state.snapshot.windows.splice(2, 1);
  const second = session(hs);
  await second.start(options);
  assert.deepEqual(await second.windows.select(1), {window: 2});
  debounce(state)!.callback();
  assert.deepEqual(savedIDs(state), [2, 1, 4]);
  second.stop();
});

test("a saved list needs a survivor still on that Desktop, and duplicates collapse", () => {
  const store = new WindowLists();
  // W moved to Desktop 2 while Atelier was stopped; A and B opened on Desktop 1 with B focused.
  const live = snapshot("1", [window(1, 10, "1"), window(2, 11, "1"), window(9, 90, "2")]);
  live.focused = 2;
  const result = store.restore([saved("1", [90, 9], [90, 9]), saved("2", [90, 9], [90, 9])], live);
  assert.deepEqual(result, {restored: 1, dropped: 1});
  assert.deepEqual(
    windowsOf(store.entries.get("D:1")!).map((w) => w.id),
    [2, 1],
  );
  assert.deepEqual(
    windowsOf(store.entries.get("D:2")!).map((w) => w.id),
    [9],
  );
  // A survivor whose membership is unknown does not anchor a Desktop by itself.
  const unknown = new WindowLists();
  unknown.restore([saved("1", [10, 100])], snapshot("1", [window(100, 10, "", {spaces: []})]));
  assert.equal(unknown.entries.size, 0);
});
