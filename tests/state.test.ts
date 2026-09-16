import assert from "node:assert/strict";
import {test} from "node:test";
import type {HS} from "../api/hs.ts";
import {createAPI} from "../api/index.ts";
import type {Snapshot, WindowInfo} from "../api/spaces.ts";
import {Groups} from "../defaults/groups.ts";
import {createDefaults} from "../defaults/index.ts";
import {
  debounceSeconds,
  parse,
  type SavedGroup,
  StateFile,
  stateVersion,
} from "../defaults/state.ts";
import {type FakeState, fakeApp, fakeHS} from "./fakes.ts";

const path = "/Users/fake/Library/Application Support/Atelier/groups.json";
const options = {overlay: false, quickApps: []};
const window = (id: number, pid: number, space: string, bundleID = "app.a"): WindowInfo => ({
  id,
  pid,
  space,
  frame: {x: 0, y: 0, w: 1, h: 1},
  title: "",
  app: bundleID,
  bundleID,
});
const snapshot = (current: string, windows: WindowInfo[], spaces = ["1", "2"]): Snapshot => ({
  trusted: true,
  focused: windows[0]?.id ?? 0,
  targetDisplay: "D",
  missionControl: false,
  displays: [{id: "D", current, spaces: spaces.map((id) => ({id, fullscreen: false}))}],
  windows,
});
const saved = (space: string, ...members: [number, number, string?][]): SavedGroup => ({
  display: "D",
  space,
  members: members.map(([pid, id, bundleID = "app.a"]) => ({pid, id, app: bundleID, bundleID})),
});
const fileText = (groups: SavedGroup[]) => JSON.stringify({version: stateVersion, groups});
/** Alive when a window with the same process, ID, and app is in the list. */
const present = (windows: WindowInfo[]) => (m: {pid: number; id: number; bundleID: string}) =>
  windows.some((w) => w.pid === m.pid && w.id === m.id && w.bundleID === m.bundleID);
const savedIDs = (state: FakeState) => parse(state.files[path]!)![0]!.members.map((m) => m.id);
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
  const groups = [saved("1", [10, 100], [11, 101])];
  groups[0]!.members[0]!.filledFrame = {x: 1, y: 2, w: 3, h: 4};
  assert.deepEqual(parse(fileText(groups)), groups);
  for (const text of [
    "{",
    "[]",
    "null",
    JSON.stringify({version: 2, groups: []}),
    JSON.stringify({version: 1, groups: {}}),
    JSON.stringify({version: 1, groups: [{display: "D", members: []}]}),
    JSON.stringify({version: 1, groups: [{display: "D", space: "1", members: [{pid: "x"}]}]}),
  ])
    assert.equal(parse(text), null, text);
  const loose = fileText([saved("1", [10, 100])]).replace(
    '"pid":10',
    '"pid":10,"filledFrame":{"x":1}',
  );
  assert.equal(parse(loose)![0]!.members[0]!.filledFrame, undefined);
});

test("serialize and restore round-trip identities and Fill frames, not titles or failures", () => {
  const store = new Groups();
  const snap = snapshot("1", [window(100, 10, "1"), window(101, 11, "1")]);
  const group = store.create(snap);
  group.members[0]!.filledFrame = {x: 1, y: 2, w: 3, h: 4};
  group.members[1]!.fillFailed = true;
  const text = fileText(store.serialize());
  const restored = new Groups();
  assert.deepEqual(restored.restore(parse(text)!, snap, present(snap.windows)), {
    restored: 1,
    dropped: 0,
  });
  assert.deepEqual(restored.serialize(), store.serialize());
  const members = restored.current(snap)!.members;
  assert.deepEqual(members[0]!.filledFrame, {x: 1, y: 2, w: 3, h: 4});
  assert.equal(members[1]!.fillFailed, undefined);
  assert.equal(members[0]!.title, "");
});

test("restore drops Groups without a Desktop and members whose window is gone or reused", () => {
  const store = new Groups();
  const visible = snapshot("1", [
    window(101, 11, "1"),
    window(102, 12, "1", "app.other"),
    window(100, 10, "1"),
    window(300, 30, "1"),
  ]);
  const result = store.restore(
    [
      saved("1", [12, 102], [10, 100], [11, 101], [13, 103]),
      saved("9", [10, 100]),
      saved("2", [20, 200]),
    ],
    visible,
    present([...visible.windows, window(200, 20, "2")]),
  );
  assert.deepEqual(result, {restored: 2, dropped: 1});
  // The reused ID 102 lost its saved slot and joins as a new window with live data.
  assert.deepEqual(
    store.entries.get("D:1")!.members.map((m) => [m.pid, m.id, m.app]),
    [
      [10, 100, "app.a"],
      [11, 101, "app.a"],
      [12, 102, "app.other"],
      [30, 300, "app.a"],
    ],
  );
  assert.deepEqual(
    store.entries.get("D:2")!.members.map((m) => [m.pid, m.id]),
    [[20, 200]],
  );
});

test("Groups on inactive Desktops stay as saved until that Desktop is visible", () => {
  const store = new Groups();
  store.restore(
    [saved("2", [20, 200], [21, 201])],
    snapshot("1", [window(100, 10, "1")]),
    present([window(200, 20, "2")]),
  );
  assert.equal(store.entries.get("D:2")!.members.length, 2);
  store.reconcile(snapshot("2", [window(201, 21, "2")]));
  assert.deepEqual(
    store.entries.get("D:2")!.members.map((m) => m.id),
    [201],
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
  assert.deepEqual(new StateFile(hs).read(), {status: "ok", groups: []});
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

test("Groups are written on stop and before reload, and come back on the next start", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2, 3]);
  const third = state.snapshot.windows.pop()!;
  const first = session(hs);
  const lines = await capture(() => first.start(options));
  assert.deepEqual(lines, ["Atelier: No saved Groups at " + path, "Atelier: Running"]);
  assert.equal(state.files[path], undefined);
  await first.group();
  await first.groups.selectMember(2);
  assert.equal(state.files[path], undefined);
  first.stop();
  assert.deepEqual(
    parse(state.files[path]!)![0]!.members.map((m) => [m.pid, m.id, m.bundleID]),
    [
      [42, 1, "fixture"],
      [42, 2, "fixture"],
    ],
  );
  assert.ok(first.status().groupsFile.savedAt);
  // The same context again, as after Reload Config or a relaunch.
  state.snapshot.windows.push(third);
  const second = session(hs);
  const restoreLines = await capture(() => second.start(options));
  assert.ok(restoreLines.includes("Atelier: Restored 1 Groups, dropped 0"));
  assert.equal(second.status().groups, 1);
  assert.deepEqual(second.status().groupsFile, {path, savedAt: null, restored: 1, dropped: 0});
  assert.equal(second.status().groupsFile.savedAt, null);
  assert.deepEqual(await second.groups.selectMember(3), {window: 3});
  debounce(state)!.callback();
  assert.deepEqual(savedIDs(state), [1, 2, 3]);
  const reload = state.keys.find((k) => k.key === "r" && k.enabled)!;
  state.snapshot.windows.pop();
  await second.groups.cycleMember(1);
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
  assert.ok(lines.includes("Atelier: Ignoring malformed Groups state at " + path));
  assert.equal(app.status().groups, 0);
  assert.deepEqual(app.status().groupsFile.restored, null);
  app.stop();
  assert.deepEqual(parse(state.files[path]!), []);
  state.files[path] = fileText([saved("9", [10, 100])]);
  await app.start();
  assert.equal(app.status().groupsFile.dropped, 1);
  debounce(state)?.callback();
  assert.deepEqual(parse(state.files[path]!), []);
  app.stop();
});

test("disabling Groups leaves the state file alone", async () => {
  const {hs, state} = fakeHS();
  const text = fileText([saved("1", [10, 100])]);
  state.files[path] = text;
  const app = session(hs);
  await app.start({...options, groups: false});
  assert.equal(app.status().groups, 0);
  app.stop();
  assert.equal(state.files[path], text);
});

test("a saved Group comes back only if one of its windows still exists somewhere", () => {
  // Display and Space IDs can repeat after a restart; identities must prove the match.
  const store = new Groups();
  const visible = snapshot("1", [window(300, 30, "1")], ["1", "2", "3"]);
  const result = store.restore(
    [saved("1", [10, 100], [11, 101]), saved("2", [20, 200], [21, 201]), saved("3")],
    visible,
    present([window(201, 21, "2")]),
  );
  assert.deepEqual(result, {restored: 1, dropped: 2});
  assert.equal(store.entries.has("D:1"), false);
  assert.deepEqual(
    store.entries.get("D:2")!.members.map((m) => m.id),
    [200, 201],
  );
  // A window that exists but belongs to another app now does not count.
  const reused = new Groups();
  reused.restore([saved("1", [10, 100])], visible, present([window(100, 10, "1", "app.other")]));
  assert.equal(reused.entries.size, 0);
});

test("a resumed session takes the file as truth, even when it is missing or broken", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2]);
  state.files[path] = fileText([{...saved("1", [42, 1, "fixture"]), display: "Main"}]);
  const app = session(hs);
  await app.start(options);
  assert.equal(app.status().groups, 1);
  app.stop();
  delete state.files[path];
  await app.start();
  assert.equal(app.status().groups, 0);
  app.stop();
  assert.deepEqual(parse(state.files[path]!), []);
  await app.start();
  await app.group();
  app.stop();
  assert.equal(parse(state.files[path]!)!.length, 1);
  state.files[path] = "{";
  await app.start();
  assert.equal(app.status().groups, 0);
  app.stop();
  assert.deepEqual(parse(state.files[path]!), []);
});

test("a reordered Group saves its latest order and restores it; the toggle forgets and recreates", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2, 3]);
  const first = session(hs);
  await first.start(options);
  await first.group();
  assert.deepEqual(await first.groups.moveMember(2), {window: 1});
  assert.deepEqual(await first.groups.moveMember(-1), {window: 1});
  assert.equal(
    state.timers.filter((t) => !t.stopped && !t.repeats && t.seconds === debounceSeconds).length,
    1,
  );
  debounce(state)!.callback();
  assert.deepEqual(savedIDs(state), [2, 1, 3]);
  assert.deepEqual(await first.groups.moveMember({slot: 2}), {noop: true});
  assert.equal(debounce(state), undefined);
  first.stop();
  // The next context: window 3 has left the Desktop and window 4 has opened.
  fakeApp(hs, state, [1, 2, 3, 4]);
  state.snapshot.windows.splice(2, 1);
  const second = session(hs);
  await second.start(options);
  assert.deepEqual(await second.groups.selectMember(1), {window: 2});
  debounce(state)!.callback();
  assert.deepEqual(savedIDs(state), [2, 1, 4]);
  // The group shortcut forgets the Group and its order; the next press starts over.
  assert.deepEqual(await second.group(), {forgotten: true});
  assert.equal(second.status().groups, 0);
  debounce(state)!.callback();
  assert.deepEqual(parse(state.files[path]!), []);
  assert.deepEqual(await second.groups.selectMember(1), {noop: true});
  state.snapshot.focused = 4;
  const recreated = await second.group();
  assert.deepEqual("members" in recreated && recreated.members.map((m) => m.id), [4, 1, 2]);
  second.stop();
});
