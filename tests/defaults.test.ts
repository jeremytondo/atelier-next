import assert from "node:assert/strict";
import {test} from "node:test";
import type {HS} from "../api/hs.ts";
import {createAPI} from "../api/index.ts";
import {type GroupPresetOption, normalize, shortcut} from "../defaults/configuration.ts";
import {Groups, isMember, type MoveTarget, moveTarget, slots} from "../defaults/groups.ts";
import {createDefaults, type DefaultsInfo, waitingSeconds} from "../defaults/index.ts";
import {parse} from "../defaults/state.ts";
import {FakeWorkspace} from "./fake-workspace.ts";
import {fakeApp, fakeHS, fakeMac} from "./fakes.ts";

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
  const group = store.create(snap);
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
    () => store.create({...snap, displays: [{...snap.displays[0]!, current: "2"}]}),
    /ordinary Desktop/,
  );
});
test("waiting slots keep their numbers as members leave and windows arrive out of order", () => {
  const store = new Groups();
  const snap = (...windows: ReturnType<typeof window>[]) => ({
    trusted: true,
    missionControl: false,
    focused: 0,
    targetDisplay: "D",
    displays: [{id: "D", current: "1", spaces: [{id: "1", fullscreen: false}]}],
    windows,
  });
  const app = (id: number, pid: number, name: string) => ({
    ...window(id, pid, "1"),
    bundleID: name,
  });
  const group = store.expect(snap());
  for (const name of ["a", "b", "c"]) store.wait(group, {bundleID: name, app: name});
  const order = () => slots(group).map((s) => (isMember(s) ? s.id : s.app));
  // The last app arrives first and keeps slot 3; a stranger appends after the named slots.
  store.reconcile(snap(app(3, 30, "c"), app(9, 90, "x")));
  assert.deepEqual(order(), ["a", "b", 3, 9]);
  // Slot 1 arrives, then leaves again: the waiting slot behind it moves up.
  store.reconcile(snap(app(1, 10, "a"), app(3, 30, "c"), app(9, 90, "x")));
  assert.deepEqual(order(), [1, "b", 3, 9]);
  store.reconcile(snap(app(3, 30, "c"), app(9, 90, "x")));
  assert.deepEqual(order(), ["b", 3, 9]);
  store.reconcile(snap(app(2, 20, "b"), app(3, 30, "c"), app(9, 90, "x")));
  assert.deepEqual(order(), [2, 3, 9]);
  // Giving up closes the gap, and a Group with nothing left is forgotten.
  store.wait(group, {bundleID: "d", app: "d"});
  assert.deepEqual(store.expire(group), ["d"]);
  assert.deepEqual(order(), [2, 3, 9]);
  store.reconcile(snap());
  assert.equal(store.entries.size, 0);
  assert.throws(() => store.expect(snap(app(1, 10, "a"))), /empty Desktop/);
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
    const group = {display: "D", space: "1", members, waiting: []},
      member = members.find((m) => m.title === title)!,
      label = JSON.stringify([start, title, target]);
    assert.equal(store.move(group, member, target), start !== expected, label);
    assert.equal(group.members.map((m) => m.title).join(""), expected, label);
  }
  // The moved member is the same object, so its Fill bookkeeping travels with it.
  const marked = {...window(1, 10, "1"), fillFailed: true, filledFrame: {x: 1, y: 2, w: 3, h: 4}};
  const group = {display: "D", space: "1", members: [marked, window(2, 10, "1")], waiting: []};
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

test("Group presets are validated before anything starts", () => {
  const preset = (extra: Partial<GroupPresetOption> & Record<string, unknown> = {}) => ({
    name: "Dev",
    apps: ["Ghostty", "Linear"],
    ...extra,
  });
  const cases: [unknown, RegExp][] = [
    [{groupPresets: {}}, /groupPresets must be an array/],
    [{groupPresets: Array(51).fill(preset())}, /at most 50/],
    [{groupPresets: [preset({name: " "})]}, /Group preset 1 needs a name/],
    [{groupPresets: [preset(), preset()]}, /"Dev" is listed twice/],
    [{groupPresets: [preset({apps: []})]}, /"Dev" needs a list of app names/],
    [{groupPresets: [preset({apps: "Ghostty"})]}, /"Dev" needs a list of app names/],
    [{groupPresets: [preset({apps: ["Ghostty", " Ghostty"]})]}, /"Dev" lists Ghostty twice/],
    [{groupPresets: [preset({apps: ["Calculator"]})]}, /"Dev" lists the Quick App Calculator/],
    [{groupPresets: [preset({size: 1})]}, /Unknown Group preset "Dev" option: size/],
    [{groupPresets: [preset({shortcut: "cmd-option-g"})]}, /"Dev" conflicts with group/],
    [{groupPresets: [preset({shortcut: "cmd-shift-c"})]}, /"Dev" conflicts with Calculator/],
    [
      {
        groupPresets: [
          preset({shortcut: "cmd-option-d"}),
          preset({name: "Two", shortcut: "cmd-alt-d"}),
        ],
      },
      /"Two" conflicts with Group preset "Dev"/,
    ],
    [{groupPresets: [preset({shortcut: "cmd-option-p"})]}, /conflicts with group-presets/],
    [{groupPresets: [preset({shortcut: "nope"})]}, /Invalid shortcut/],
    [{groups: false, groupPresets: [preset({name: ""})]}, /needs a name/],
  ];
  for (const [given, message] of cases)
    assert.throws(() => normalize(given), message, JSON.stringify(given));
  const config = normalize({
    groupPresets: [preset({shortcut: "cmd-option-d"}), preset({name: "Writing"})],
  });
  assert.deepEqual(config.groupPresets[0], {
    name: "Dev",
    apps: ["Ghostty", "Linear"],
    shortcut: {text: "cmd-option-d", mods: ["cmd", "alt"], key: "d", identity: "alt+cmd:d"},
  });
  assert.deepEqual(config.groupPresets[1], {name: "Writing", apps: ["Ghostty", "Linear"]});
  const picker = config.shortcuts.find((b) => b.name === "group-presets")!;
  assert.deepEqual([picker.mods, picker.key], [["cmd", "alt"], "p"]);
  assert.equal(
    normalize({bindings: {"group-presets": "none"}}).shortcuts.some(
      (b) => b.name === "group-presets",
    ),
    false,
  );
  assert.deepEqual(normalize({groups: false}).groupPresets, []);
});

/** An empty Desktop over a fake Mac; the inventory lists its on-screen windows. */
function presetSession(groupPresets: GroupPresetOption[]) {
  const {hs, state} = fakeHS();
  const mac = new FakeWorkspace();
  mac.apps.clear();
  mac.wins.clear();
  mac.front = null;
  mac.focused = 0;
  // Launched apps show a window only when the test places one.
  mac.launchedWindowFrame = null;
  const fake = fakeMac(hs, state, mac);
  Object.defineProperty(state.snapshot, "windows", {
    get: () => {
      const windows = [];
      for (const [pid, app] of mac.apps) {
        if (app.hidden) continue;
        for (const id of app.windows) {
          const win = mac.wins.get(id);
          if (!win || win.minimized) continue;
          windows.push({
            id,
            pid,
            space: win.spaces[0] ?? "1",
            frame: {...win.frame},
            title: "",
            app: app.bundleID.slice(4),
            bundleID: app.bundleID,
          });
        }
      }
      return windows;
    },
  });
  const app = session(hs, {workspace: () => mac});
  return {
    state,
    mac,
    fake,
    app,
    /** A running app with one window whose ID is ten times the PID. */
    place(
      pid: number,
      name: string,
      where: {hidden?: boolean; minimized?: boolean; space?: string} = {},
    ) {
      mac.apps.set(pid, {
        bundleID: "app." + name,
        hidden: where.hidden ?? false,
        windows: [pid * 10],
      });
      mac.wins.set(pid * 10, {
        frame: {x: 0, y: 0, w: 400, h: 300},
        minimized: where.minimized ?? false,
        spaces: [where.space ?? "1"],
      });
    },
    start: () => app.start({...options, groupPresets}),
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
  const result = await f.app.groups.applyPreset("Dev");
  assert.ok("group" in result);
  assert.deepEqual(
    result.group.members.map((m) => m.id),
    [300, 320],
  );
  assert.deepEqual(result.group.waiting, [{bundleID: "app.Fresh", app: "Fresh", position: 0}]);
  assert.deepEqual(result.skipped, ["Elsewhere"]);
  assert.deepEqual(f.mac.launches, ["app.Fresh"]);
  assert.equal(f.mac.apps.get(30)!.hidden, false);
  assert.equal(f.mac.wins.get(320)!.minimized, false);
  // Nothing was activated: slot 1 is still waiting, and the app elsewhere was left alone.
  assert.equal(f.mac.front, null);
  assert.equal(f.state.snapshot.focused, 0);
  assert.equal(f.app.status().groups, 1);
  assert.deepEqual(await f.app.groups.selectMember(1), {noop: true});
  assert.deepEqual(await f.app.groups.selectMember(2), {window: 300});
  assert.deepEqual(f.fake.fills, [300]);
  // The launched window takes slot 1 when it appears; later windows append after the named slots.
  f.place(20, "Fresh");
  assert.deepEqual(await f.app.groups.selectMember(1), {window: 200});
  f.place(40, "Later");
  assert.deepEqual(await f.app.groups.selectMember(3), {window: 320});
  assert.deepEqual(await f.app.groups.selectMember(4), {window: 400});
  f.timer()!.callback();
  assert.deepEqual(await f.app.groups.selectMember(1), {window: 200});
  f.app.stop();
});

test("a preset refuses a non-empty, fullscreen, or already waiting Desktop and changes nothing", async () => {
  const f = presetSession([{name: "Dev", apps: ["Fresh"]}]);
  f.place(30, "Open");
  await f.start();
  await assert.rejects(f.app.groups.applyPreset("Dev"), /empty Desktop/);
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
  await assert.rejects(f.app.groups.applyPreset("Dev"), /ordinary Desktop/);
  assert.deepEqual(f.mac.launches, []);
  assert.equal(f.app.status().groups, 0);
  f.state.snapshot.displays = [ordinary];
  await f.app.groups.applyPreset("Dev");
  await assert.rejects(f.app.groups.applyPreset("Dev"), /already waiting/);
  assert.deepEqual(f.mac.launches, ["app.Fresh"]);
  await assert.rejects(f.app.groups.applyPreset("Nope"), /not configured/);
  f.app.stop();
});

test("waiting slots close ranks after a failed launch or the timeout, and the toggle cancels them", async () => {
  const f = presetSession([{name: "Dev", apps: ["Broken", "Slow", "Quick"]}]);
  f.mac.launchFailures.add("app.Broken");
  await f.start();
  const result = await f.app.groups.applyPreset("Dev");
  assert.deepEqual("skipped" in result && result.skipped, ["Broken"]);
  assert.deepEqual(f.mac.launches, ["app.Slow", "app.Quick"]);
  // Quick keeps slot 2 while Slow is still expected in slot 1.
  f.place(21, "Quick");
  assert.deepEqual(await f.app.groups.selectMember(1), {noop: true});
  assert.deepEqual(await f.app.groups.selectMember(2), {window: 210});
  f.timer()!.callback();
  assert.deepEqual(await f.app.groups.selectMember(1), {window: 210});
  f.place(20, "Slow");
  assert.deepEqual(await f.app.groups.selectMember(2), {window: 200});
  f.app.stop();
  const g = presetSession([{name: "Solo", apps: ["Fresh"]}]);
  await g.start();
  await g.app.groups.applyPreset("Solo");
  assert.equal(g.app.status().groups, 1);
  assert.equal(g.state.watched.length, 0);
  assert.deepEqual(await g.app.group(), {forgotten: true});
  assert.equal(g.app.status().groups, 0);
  g.timer()!.callback();
  g.place(20, "Fresh");
  assert.deepEqual(await g.app.groups.selectMember(1), {noop: true});
  assert.equal(g.app.status().groups, 0);
  g.app.stop();
});

test("presets fill the picker and their shortcuts, skip missing apps, and stay off with Groups", async () => {
  const {hs, state} = fakeHS();
  const mac = new FakeWorkspace();
  state.missingApps = ["Ghost"];
  const app = session(hs, {workspace: () => mac});
  await app.start({
    ...options,
    groupPresets: [
      {name: "Dev", shortcut: "cmd-option-d", apps: ["Ghost", "Fresh"]},
      {name: "Writing", apps: ["Obsidian", "Safari"]},
    ],
  });
  assert.match(app.status().error ?? "", /Group preset "Dev": No application named Ghost/);
  assert.deepEqual(app.status().groupPresets, [
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
  const applied = () => app.status().metrics.filter((m) => m.name === "applyPreset").length;
  chooser.onSelect!({text: "Dev"});
  for (let i = 0; i < 100 && applied() === 0; i++) await Promise.resolve();
  assert.equal(applied(), 1);
  assert.deepEqual(mac.launches, ["app.Fresh"]);
  app.stop();
  for (const extra of [{}, {groups: false}]) {
    const {hs: other, state: otherState} = fakeHS();
    const bare = session(other, {workspace: () => new FakeWorkspace()});
    await bare.start({
      ...options,
      ...extra,
      groupPresets:
        "groups" in extra ? [{name: "Dev", shortcut: "cmd-option-d", apps: ["Fresh"]}] : [],
    });
    assert.equal(otherState.choosers.length, 0, JSON.stringify(extra));
    assert.ok(!otherState.keys.some((k) => ["p", "d"].includes(k.key)), JSON.stringify(extra));
    bare.stop();
  }
});

test("a revealed slot 1 takes focus and Fill; a launched one never does", async () => {
  const revealed = presetSession([{name: "Dev", apps: ["Hidden", "Fresh"]}]);
  revealed.place(30, "Hidden", {hidden: true});
  await revealed.start();
  await revealed.app.groups.applyPreset("Dev");
  assert.equal(revealed.state.snapshot.focused, 300);
  assert.deepEqual(revealed.fake.fills, [300]);
  revealed.app.stop();
  // The launched app shows its window before the apply finishes.
  const launched = presetSession([{name: "Dev", apps: ["Fresh", "Hidden"]}]);
  launched.place(30, "Hidden", {hidden: true});
  launched.mac.launchedWindowFrame = {x: 0, y: 0, w: 400, h: 300};
  await launched.start();
  const result = await launched.app.groups.applyPreset("Dev");
  assert.deepEqual("group" in result && result.group.members.map((m) => m.id), [200, 300]);
  assert.equal(launched.state.snapshot.focused, 0);
  assert.deepEqual(launched.fake.fills, []);
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
      app.start({...options, quickApps: [...quickApps], groupPresets: [...presets]}),
      message,
    );
    assert.equal(app.status().state, "Stopped");
    assert.equal(state.keys.length, 0);
  }
});

test("starting again with Groups disabled drops the Groups still in memory", async () => {
  const f = presetSession([{name: "Solo", apps: ["Fresh"]}]);
  await f.start();
  await f.app.groups.applyPreset("Solo");
  assert.equal(f.app.status().groups, 1);
  f.app.stop();
  await f.app.start({...options, groups: false});
  assert.equal(f.app.status().groups, 0);
  f.app.stop();
});
