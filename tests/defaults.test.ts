import assert from "node:assert/strict";
import {test} from "node:test";
import type {HS} from "../api/hs.ts";
import {createAPI} from "../api/index.ts";
import {normalize, shortcut} from "../defaults/configuration.ts";
import {Groups, type MoveTarget, moveTarget} from "../defaults/groups.ts";
import {createDefaults, type DefaultsInfo} from "../defaults/index.ts";
import {parse} from "../defaults/state.ts";
import {FakeWorkspace} from "./fake-workspace.ts";
import {fakeApp, fakeHS} from "./fakes.ts";

const options = {overlay: false, quickApps: []};
const path = "/Users/fake/Library/Application Support/Atelier/groups.json";
const window = (id: number, pid: number, space: string) => ({
  id,
  pid,
  space,
  frame: {x: 0, y: 0, w: 1, h: 1},
  title: "",
  app: "",
  bundleID: "",
});
function session(hs: HS, extra: Partial<DefaultsInfo> = {}) {
  const api = createAPI(hs, {providers: "/share/atelier/atelier-providers"});
  return createDefaults(hs, api, {expectedBuild: "133.1", version: "test", ...extra});
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
    normalize({groups: false}).shortcuts.some((b) => b.name.startsWith("move-")),
    false,
  );
  assert.throws(
    () => normalize({bindings: {"move-1": "cmd-option-1"}}),
    /move-1 conflicts with select-1/,
  );
  assert.equal(shortcut("command-option-minus").identity, shortcut("alt-cmd--").identity);
  assert.throws(() => normalize({bindings: {"desktop-create": "alt-1"}}), /conflicts/);
  assert.throws(
    () => normalize({quickApps: [{app: "Calculator", shortcut: "cmd-alt-g"}]}),
    /conflicts/,
  );
  assert.throws(
    () => normalize({quickApps: [{app: "A", shortcut: "cmd-a", size: {width: -1, height: 20}}]}),
    /size/,
  );
  assert.throws(() => normalize({launchAtLogin: true}), /Unknown Atelier option/);
});

test("groups retain inactive membership, distinguish PID reuse, and exclude fullscreen", () => {
  const store = new Groups();
  const snap = {
    trusted: true,
    missionControl: false,
    focused: 2,
    targetDisplay: "D",
    displays: [
      {
        id: "D",
        current: "1",
        spaces: [
          {id: "1", fullscreen: false},
          {id: "2", fullscreen: true},
        ],
      },
    ],
    windows: [1, 2].map((id) => window(id, 10, "1")),
  };
  const group = store.repair(snap);
  assert.deepEqual(
    group.members.map((w) => w.id),
    [2, 1],
  );
  store.reconcile({...snap, displays: [{...snap.displays[0]!, current: "2"}], windows: []});
  assert.equal(group.members.length, 2);
  store.reconcile({...snap, windows: [window(1, 11, "1"), window(2, 10, "1")]});
  assert.deepEqual(
    group.members.map((w) => [w.pid, w.id]),
    [
      [10, 2],
      [11, 1],
    ],
  );
  assert.throws(
    () => store.repair({...snap, displays: [{...snap.displays[0]!, current: "2"}]}),
    /ordinary Desktop/,
  );
});

test("moving a member keeps the others in order, stops at the edges, and rejects bad targets", () => {
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
  const store = new Groups();
  for (const [start, title, target, expected] of cases) {
    const members = [...start].map((letter, i) => ({...window(i + 1, 10, "1"), title: letter}));
    const group = {display: "D", space: "1", members},
      member = members.find((m) => m.title === title)!,
      label = JSON.stringify([start, title, target]);
    assert.equal(store.move(group, member, target), start !== expected, label);
    assert.equal(group.members.map((m) => m.title).join(""), expected, label);
  }
  // The moved member is the same object, so its Fill bookkeeping travels with it.
  const marked = {...window(1, 10, "1"), fillFailed: true, filledFrame: {x: 1, y: 2, w: 3, h: 4}};
  const group = {display: "D", space: "1", members: [marked, window(2, 10, "1")]};
  assert.equal(store.move(group, marked, 1), true);
  assert.equal(group.members[1], marked);
  assert.equal(store.move(group, window(3, 10, "1"), -1), false);
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
  state.failBinding = "g";
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
  state.failBinding = "g";
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

test("grouping fills only the front member and selection focuses exact same-app windows", async () => {
  const {hs, state} = fakeHS();
  const {fills, application} = fakeApp(hs, state, [1, 2]);
  const app = session(hs);
  await app.start(options);
  await app.group();
  assert.deepEqual(fills, [1]);
  assert.equal(state.watched.length, 1);
  assert.notEqual(state.watched[0]![0], application);
  assert.ok((state.watched[0]![1] as string[]).includes("AXWindowCreated"));
  assert.ok((state.watched[0]![1] as string[]).includes("AXFocusedWindowChanged"));
  await app.groups.selectMember(2);
  assert.equal(state.snapshot.focused, 2);
  assert.deepEqual(fills, [1, 2]);
  await app.groups.selectMember(2);
  assert.deepEqual(fills, [1, 2]);
  app.stop();
  assert.deepEqual(state.removedWatchers, state.watched);
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
    if (failure === "shortcut") state.failBinding = "g";
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

test("moving the focused member changes only the order and leaves focus, Fill, and Spaces alone", async () => {
  const {hs, state} = fakeHS();
  const fake = fakeApp(hs, state, [1, 2, 3, 4]);
  fake.fillAvailable = false;
  const app = session(hs);
  await app.start(options);
  await assert.rejects(app.group(), /not supported/);
  fake.fillAvailable = true;
  const requests = state.requests.length;
  assert.deepEqual(await app.groups.moveMember({slot: 4}), {window: 1});
  assert.deepEqual(await app.groups.moveMember(-2), {window: 1});
  assert.ok(state.requests.slice(requests).every((r) => r.command === "spaces.snapshot"));
  assert.equal(state.snapshot.focused, 1);
  assert.deepEqual(fake.fills, []);
  // The order is 2, 1, 3, 4, and the moved member keeps its failed-Fill suppression.
  assert.deepEqual(await app.groups.selectMember(2), {window: 1});
  assert.deepEqual(fake.fills, []);
  assert.deepEqual(await app.groups.selectMember(1), {window: 2});
  assert.deepEqual(fake.fills, [2]);
  // The shortcut moves once per press, and the running Fill settlement follows the member.
  const moveKeys = state.keys.filter((k) => k.mods.includes("shift"));
  assert.equal(moveKeys.length, 12);
  assert.ok(moveKeys.every((k) => k.repeat === null));
  const moves = () => app.status().metrics.filter((m) => m.name === "moveMember").length;
  const before = moves();
  moveKeys.find((k) => k.key === "]")!.callback();
  for (let i = 0; i < 100 && moves() === before; i++) await Promise.resolve();
  assert.equal(moves(), before + 1);
  assert.deepEqual(await app.groups.selectMember(2), {window: 2});
  assert.deepEqual(fake.fills, [2]);
  app.stop();
});

test("a move needs a Group, a focused member, valid arguments, and a free session", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2, 3]);
  const third = state.snapshot.windows.pop()!;
  const app = session(hs);
  await app.start(options);
  assert.deepEqual(await app.groups.moveMember(1), {noop: true});
  await app.group();
  state.snapshot.focused = 77;
  assert.deepEqual(await app.groups.moveMember(1), {noop: true});
  // A window that became eligible since the last snapshot is a member at once.
  state.snapshot.windows.push(third);
  state.snapshot.focused = 3;
  assert.deepEqual(await app.groups.moveMember({slot: 1}), {window: 3});
  await assert.rejects(app.groups.moveMember(1.5), /move target/);
  await assert.rejects(app.groups.moveMember({slot: 0}), /move target/);
  // A move during another action is dropped; a cancelled snapshot leaves the order alone.
  state.replies = false;
  const pending = app.groups.moveMember({slot: 3}),
    rejected = assert.rejects(pending, /stopped/);
  assert.deepEqual(await app.groups.moveMember(1), {busy: true});
  app.stop();
  await rejected;
  assert.deepEqual(
    parse(state.files[path]!)![0]!.members.map((m) => m.id),
    [3, 1, 2],
  );
});
