import assert from "node:assert/strict";
import {test} from "node:test";
import {createWindow, nativeActionNames} from "../api/window.ts";
import {fakeHS, fakeMenuBar, windowMenu} from "./fakes.ts";

test("the native actions are read from the Window menu by identifier, with reliable shortcuts only", () => {
  const {hs} = fakeHS();
  const bar = fakeMenuBar(hs, [
    {title: "File", children: [{children: [{title: "New", identifier: "newDocument:"}]}]},
    windowMenu(),
  ]);
  const menu = createWindow(hs).actions();
  assert.deepEqual([menu.app, menu.pid, menu.window], ["Fixture", 42, 7]);
  assert.ok(
    nativeActionNames.every((name) => menu.actions[name].present && menu.actions[name].enabled),
  );
  assert.deepEqual(menu.actions.fill.shortcut, {mods: ["fn", "ctrl"], key: "f"});
  assert.deepEqual(menu.actions["left-right"].shortcut, {
    mods: ["fn", "ctrl", "shift"],
    key: "left",
  });
  assert.deepEqual(menu.actions["top-quarters"].shortcut, {
    mods: ["fn", "ctrl", "alt", "shift"],
    key: "up",
  });
  // Corners have no shortcut at all; nothing is guessed for them.
  assert.equal(menu.actions["top-left"].shortcut, null);
  assert.equal(menu.actions.quarters.shortcut, null);
  // A modifier mask outside the readable bits, or a key that is not a character, gives no hint.
  const items = bar.menus[1]!.children![0]!.children!,
    submenu = items.find((i) => i.title === "Move & Resize")!.children![0]!.children!;
  items.find((i) => i.identifier === "_zoomFill:")!.char = "\t";
  Object.assign(submenu.find((i) => i.identifier === "_zoomQuarters:")!, {char: "Q", mods: 64});
  const odd = createWindow(hs).actions();
  assert.equal(odd.actions.fill.shortcut, null);
  assert.equal(odd.actions.quarters.shortcut, null);
  assert.deepEqual(bar.pressed, []);
});

test("a localized Window menu is still found, and apps without the actions report none", () => {
  const {hs} = fakeHS();
  const german = windowMenu();
  german.title = "Fenster";
  const bar = fakeMenuBar(hs, [
    {title: "Ablage", children: [{children: [{title: "Neu"}]}]},
    german,
  ]);
  assert.equal(createWindow(hs).actions().actions.center.present, true);
  bar.menus = [
    {title: "Window", children: [{children: [{title: "Minimize", identifier: "_NS:371"}]}]},
  ];
  const none = createWindow(hs).actions();
  assert.ok(nativeActionNames.every((name) => !none.actions[name].present));
  bar.app = null;
  assert.equal(createWindow(hs).actions().app, null);
});

test("perform presses the enabled item for the same focused window and refuses anything else", () => {
  const {hs} = fakeHS();
  const bar = fakeMenuBar(hs, [windowMenu()]);
  const api = createWindow(hs);
  assert.deepEqual(api.perform("fill"), {window: 7});
  assert.deepEqual(bar.pressed, ["_zoomFill::AXPress"]);
  bar.menus = [windowMenu(false)];
  assert.throws(
    () => api.perform("left-right"),
    /Left & Right is unavailable for the focused window/,
  );
  bar.menus = [{title: "Window", children: [{children: []}]}];
  assert.throws(() => api.perform("center"), /Center is not in the Window menu of Fixture/);
  bar.menus = [windowMenu()];
  bar.pressResult = false;
  assert.throws(() => api.perform("quarters"), /Fixture refused Quarters/);
  bar.pressResult = true;
  // Focus moving between the read and the press cancels the action.
  let reads = 0;
  hs.window.focusedWindow = (() => ({
    id: reads++ ? 8 : 7,
    pid: 42,
  })) as unknown as typeof hs.window.focusedWindow;
  assert.throws(() => api.perform("top"), /focused window changed/);
  assert.equal(bar.pressed.length, 2);
  hs.window.focusedWindow = (() => null) as unknown as typeof hs.window.focusedWindow;
  assert.throws(() => api.perform("top"), /No focused window in Fixture/);
  hs.window.focusedWindow = (() => ({id: 7, pid: 43})) as unknown as typeof hs.window.focusedWindow;
  assert.throws(() => api.perform("top"), /No focused window in Fixture/);
  hs.window.focusedWindow = (() => ({
    id: -1,
    pid: 42,
  })) as unknown as typeof hs.window.focusedWindow;
  assert.throws(() => api.perform("top"), /No focused window in Fixture/);
  assert.equal(bar.pressed.length, 2);
  hs.window.focusedWindow = (() => bar.focused) as unknown as typeof hs.window.focusedWindow;
  bar.app = null;
  assert.throws(() => api.perform("top"), /No application is frontmost/);
  assert.throws(() => api.perform("nope" as never), /Unknown window action/);
});
