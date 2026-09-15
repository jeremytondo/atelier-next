import assert from "node:assert/strict";
import {test} from "node:test";
import {QuickApps, windowTimeout} from "../defaults/quick-apps.ts";
import {desktop, display, FakeWorkspace, quick} from "./fake-workspace.ts";

async function failure(mac: FakeWorkspace, size?: {width: number; height: number}) {
  try {
    await new QuickApps(mac).toggle(quick, size);
    return null;
  } catch (error) {
    return (error as Error).message;
  }
}

test("summon launches, places, pins, and focuses", async () => {
  const mac = new FakeWorkspace();
  const apps = new QuickApps(mac);
  const shown = await apps.toggle(quick);
  assert.deepEqual(mac.launches, [quick.bundleID]);
  assert.equal(shown.action, "shown");
  assert.equal(shown.window, 200);
  assert.equal(shown.display, "A");
  assert.equal(shown.space, "1");
  assert.equal(shown.assignment, "assigned");
  assert.equal(mac.pins.length, 1);
  assert.deepEqual(mac.pins[0]!.required, ["1", "2"]);
  // An oversized window shrinks to the usable area, inset by 8 points, and centers there.
  const usable = {x: 8, y: 33, w: 1440 - 16, h: 875 - 16};
  const frame = mac.frame(200)!;
  assert.equal(frame.w, usable.w);
  assert.equal(frame.h, usable.h);
  assert.equal(frame.x + frame.w / 2, usable.x + usable.w / 2);
  assert.equal(frame.y + frame.h / 2, usable.y + usable.h / 2);
  assert.equal(mac.focused, 200);
  assert.equal(mac.front, 20);
  assert.deepEqual(apps.states.get(quick.bundleID)!.previous, {
    pid: 10,
    bundleID: "com.example.editor",
  });
});

test("hiding restores the window the user came from", async () => {
  const mac = new FakeWorkspace();
  const apps = new QuickApps(mac);
  await apps.toggle(quick);
  const hidden = await apps.toggle(quick);
  assert.deepEqual(hidden, {action: "hidden", bundleID: quick.bundleID, restoredFocus: true});
  assert.equal(mac.apps.get(20)!.hidden, true);
  assert.equal(mac.focused, 100);
  assert.equal(mac.front, 10);
  assert.equal(apps.states.get(quick.bundleID)!.previous, null);
  // The next press summons the hidden app again without relaunching it.
  const again = await apps.toggle(quick);
  assert.equal(again.action, "shown");
  assert.equal(mac.launches.length, 1);
  assert.equal(mac.apps.get(20)!.hidden, false);
  assert.equal(mac.focused, 200);
});

test("hiding does not restore a window that moved, minimized, or quit", async () => {
  for (const scenario of ["moved", "minimized", "quit"]) {
    const mac = new FakeWorkspace();
    const apps = new QuickApps(mac);
    await apps.toggle(quick);
    if (scenario === "moved") mac.wins.get(100)!.spaces = ["2"];
    else if (scenario === "minimized") mac.wins.get(100)!.minimized = true;
    else mac.apps.delete(10);
    const hidden = await apps.toggle(quick);
    assert.equal(hidden.restoredFocus, false, scenario);
    assert.equal(mac.apps.get(20)!.hidden, true, scenario);
    assert.equal(mac.focused, 0, scenario);
  }
});

test("a repeated press while minimized keeps the original app", async () => {
  const mac = new FakeWorkspace();
  const apps = new QuickApps(mac);
  await apps.toggle(quick);
  mac.wins.get(200)!.minimized = true;
  const shown = await apps.toggle(quick);
  assert.equal(shown.action, "shown");
  assert.equal(mac.wins.get(200)!.minimized, false);
  assert.equal(mac.launches.length, 1);
  assert.equal(apps.states.get(quick.bundleID)!.previous?.pid, 10);
  const hidden = await apps.toggle(quick);
  assert.equal(hidden.restoredFocus, true);
  assert.equal(mac.focused, 100);
});

test("summon refuses fullscreen Desktops and Desktop changes", async () => {
  const fullscreen = new FakeWorkspace();
  fullscreen.topology = [display([desktop("1"), desktop("90", true)], "90")];
  assert.match((await failure(fullscreen)) ?? "", /ordinary Desktop/);
  assert.deepEqual(fullscreen.launches, []);
  const moved = new FakeWorkspace();
  moved.changeDesktopAfterLaunch = true;
  assert.match((await failure(moved)) ?? "", /Active Desktop changed/);
  assert.deepEqual(moved.pins, []);
});

test("summon reports apps without a standard window after the timeout", async () => {
  const mac = new FakeWorkspace();
  mac.launchedWindowFrame = null;
  assert.match((await failure(mac)) ?? "", /did not expose a standard window/);
  assert.ok(mac.time >= windowTimeout);
});

test("an invalid size is refused before touching the app", async () => {
  const mac = new FakeWorkspace();
  assert.match((await failure(mac, {width: 0, height: 10})) ?? "", /Invalid quick app size/);
  assert.deepEqual(mac.launches, []);
});

test("a requested size fits the usable area and the app minimum wins", async () => {
  const mac = new FakeWorkspace();
  mac.minimumSize = {w: 500, h: 400};
  const shown = await new QuickApps(mac).toggle(quick, {width: 300, height: 5000});
  const usable = {x: 8, y: 33, w: 1440 - 16, h: 875 - 16};
  const frame = shown.frame!;
  assert.equal(frame.w, 500);
  assert.equal(frame.h, usable.h);
  assert.equal(frame.x + frame.w / 2, usable.x + usable.w / 2);
  assert.equal(frame.y + frame.h / 2, usable.y + usable.h / 2);
});

test("later failures keep the window identity for the next press", async () => {
  const refused = new FakeWorkspace();
  refused.pinFails = true;
  assert.match((await failure(refused)) ?? "", /Dock automation failed/);

  const unverified = new FakeWorkspace();
  unverified.pinSpreads = false;
  const apps = new QuickApps(unverified);
  await assert.rejects(apps.toggle(quick), /every Desktop/);
  assert.equal(apps.states.get(quick.bundleID)!.window, 200);
  assert.equal(unverified.focused, 100);

  const unfocused = new FakeWorkspace();
  unfocused.focusWorks = false;
  assert.match((await failure(unfocused)) ?? "", /Could not focus/);
  assert.ok(unfocused.time >= 1.5);
});

test("hide failures are reported", async () => {
  for (const refused of [true, false]) {
    const mac = new FakeWorkspace();
    const apps = new QuickApps(mac);
    await apps.toggle(quick);
    mac.hideRefused = refused;
    mac.hideIgnored = !refused;
    await assert.rejects(apps.toggle(quick), refused ? /Could not hide/ : /verify/);
  }
});
