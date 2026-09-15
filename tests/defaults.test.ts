import assert from "node:assert/strict";
import {test} from "node:test";
import type {HS} from "../api/hs.ts";
import {createAPI} from "../api/index.ts";
import {normalize, shortcut} from "../defaults/configuration.ts";
import {Groups} from "../defaults/groups.ts";
import {createDefaults, type DefaultsInfo} from "../defaults/index.ts";
import {FakeWorkspace} from "./fake-workspace.ts";
import {fakeHS} from "./fakes.ts";

const options = {overlay: false, quickApps: []};
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
  const window = (id: number, pid: number, space: string) => ({
    id,
    pid,
    space,
    frame: {x: 0, y: 0, w: 1, h: 1},
    title: "",
    app: "",
    bundleID: "",
  });
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

test("missing Accessibility asks for it and leaves defaults stopped without active shortcuts", async () => {
  const {hs, state} = fakeHS();
  state.trusted = false;
  const app = session(hs);
  await assert.rejects(app.start(options), /Accessibility/);
  assert.equal(state.accessibilityRequests, 1);
  assert.ok(state.notifications.some((n) => /Accessibility/.test(n)));
  assert.equal(state.keys.length, 0);
  assert.equal(state.tasks[0]!.isRunning, false);
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
  const {hs, state} = fakeHS(),
    fills: number[] = [];
  const application: Record<string, unknown> = {
    axElement: () => ({setAttributeValueValue: () => true}),
  };
  const windows = [1, 2].map((id) => ({
    id,
    pid: 42,
    application,
    frame: {x: 0, y: 0, w: 400, h: 300},
    axElement: () => ({
      setAttributeValueValue: () => true,
      performAction: () => {
        state.snapshot.focused = id;
        return true;
      },
    }),
  }));
  application.allWindows = windows;
  hs.application.fromPID = (() => application) as unknown as typeof hs.application.fromPID;
  hs.window.focusedWindow = (() =>
    windows.find(
      (w) => w.id === state.snapshot.focused,
    )) as unknown as typeof hs.window.focusedWindow;
  hs.ax.applicationElement = (() => ({
    attributeValue: () => ({
      attributeValue: (name: string) => (name === "AXIdentifier" ? "_zoomFill:" : null),
      children: () => [],
      isEnabled: true,
      performAction: () => {
        fills.push(state.snapshot.focused);
        return true;
      },
    }),
  })) as unknown as typeof hs.ax.applicationElement;
  state.snapshot.focused = 1;
  state.snapshot.windows = windows.map((w) => ({
    id: w.id,
    pid: 42,
    space: "1",
    app: "Fixture",
    bundleID: "fixture",
    title: "",
    frame: w.frame,
  }));
  const app = session(hs);
  await app.start(options);
  await app.group();
  assert.deepEqual(fills, [1]);
  assert.equal(state.watched.length, 1);
  assert.notEqual(state.watched[0]![0], application);
  assert.ok((state.watched[0]![1] as string[]).includes("AXWindowCreated"));
  assert.ok((state.watched[0]![1] as string[]).includes("AXFocusedWindowChanged"));
  await app.select(2);
  assert.equal(state.snapshot.focused, 2);
  assert.deepEqual(fills, [1, 2]);
  await app.select(2);
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
    if (["options", "permission", "shortcut"].includes(failure ?? "")) {
      await assert.rejects(app.start(failure === "options" ? {unknown: true} : options));
    } else {
      await app.start(options);
      if (failure === "providers") {
        state.tasks[0]!.ended(9, "crash");
        assert.equal(app.status().state, "Paused", failure);
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
