import assert from "node:assert/strict";
import {test} from "node:test";
import {frameFor} from "../defaults/hud.ts";
import {Overlay} from "../defaults/overlay.ts";
import type {DesktopWindows, ListedWindow} from "../defaults/windows.ts";
import {type FakeCanvas, fakeHS} from "./fakes.ts";

const listed = (pid: number, id: number, app: string, title = ""): ListedWindow => ({
  pid,
  id,
  launched: 1,
  app,
  bundleID: app,
  title,
  visible: true,
});

// Records canvas lifetime and input events; does not simulate macOS placement.
function fixture(chord = ["cmd", "alt"]) {
  const {hs, state} = fakeHS();
  hs.window.focusedWindow = (() => ({pid: 10, id: 1})) as unknown as typeof hs.window.focusedWindow;
  const store: {snapshot: {missionControl: boolean}; desktop: DesktopWindows | null} = {
    snapshot: {missionControl: false},
    desktop: {
      display: "D",
      space: "2",
      slots: [listed(10, 1, "Fixture", "Saved window")],
    },
  };
  const redraw = () => overlay.update(store.snapshot, store.desktop);
  const overlay = new Overlay(hs, chord, redraw);
  overlay.start();
  const tap = state.taps[0]!;
  assert.equal(tap.listenOnly, true);
  return {
    state: store,
    canvases: state.canvases,
    overlay,
    redraw,
    removed: () => tap.removed,
    flags: (flags: string[]) =>
      assert.equal(tap.callback({type: 12, keyCode: 0, flags}), hs.eventtap.emit),
  };
}

const rows = (canvas: FakeCanvas) =>
  canvas.elements
    .filter((e) => e.text && !/WINDOWS|Release/.test(e.text))
    .map((e) => [e.text, e.textColor?.alpha]);

test("the panel sits at the bottom of a screen above the primary", () => {
  assert.deepEqual(frameFor({x: 0, y: -900, w: 1200, h: 900}, {h: 1000}, 320, 200), {
    x: 860,
    y: 1020,
    w: 320,
    h: 200,
  });
  assert.deepEqual(frameFor({x: 0, y: 0, w: 1200, h: 800}, {h: 800}, 360, 200, "bottomCenter"), {
    x: 420,
    y: 20,
    w: 360,
    h: 200,
  });
});

test("overlay replaces its native window when the list moves between Spaces or displays", () => {
  const f = fixture();
  f.flags(["cmd", "alt"]);
  const first = f.canvases[0]!;
  f.redraw();
  assert.equal(first.shows, 1);
  // Keep identical content and focus to exercise placement independently of drawing.
  for (const [display, space] of [
    ["D", "3"],
    ["D", "2"],
    ["Main", "2"],
  ] as const) {
    const previous = f.canvases.at(-1)!;
    f.state.desktop = {...f.state.desktop!, display, space};
    f.redraw();
    assert.equal(previous.destroyed, true);
    assert.notEqual(f.canvases.at(-1), previous);
    assert.equal(f.canvases.at(-1)!.showing, true);
  }
  f.overlay.stop();
  assert.ok(f.canvases.every((c) => c.destroyed));
  assert.equal(f.removed(), true);
});

test("overlay shows the second Desktop's list after releasing modifiers on the first", () => {
  const f = fixture();
  f.flags(["cmd", "alt"]);
  f.flags([]);
  assert.equal(f.canvases[0]!.showing, false);
  f.state.desktop = {
    ...f.state.desktop!,
    space: "3",
    slots: [listed(20, 2, "Second app", "Second window")],
  };
  f.flags(["cmd", "alt"]);
  assert.equal(f.canvases[0]!.destroyed, true);
  assert.equal(f.canvases.at(-1)!.showing, true);
  assert.ok(f.canvases.at(-1)!.elements.some((e) => e.text === "Second app"));
  f.flags([]);
  assert.equal(f.canvases.at(-1)!.showing, false);
  f.overlay.stop();
});

test("overlay hides during Mission Control and on Desktops without a list, then shows again", () => {
  const f = fixture(),
    desktop = f.state.desktop;
  f.flags(["cmd", "alt"]);
  f.state.snapshot.missionControl = true;
  f.redraw();
  assert.equal(f.canvases.at(-1)!.showing, false);
  f.state.snapshot.missionControl = false;
  f.redraw();
  assert.equal(f.canvases.at(-1)!.showing, true);
  f.state.desktop = null;
  f.redraw();
  assert.equal(f.canvases.at(-1)!.showing, false);
  f.state.desktop = desktop;
  f.redraw();
  assert.equal(f.canvases.at(-1)!.showing, true);
  f.overlay.stop();
});

test("overlay chord allows Shift, hides on other extra modifiers, and needs a configured Shift", () => {
  const cases: [string[], string[], boolean][] = [
    [["cmd", "alt"], ["cmd", "alt"], true],
    [["cmd", "alt"], ["cmd", "alt", "shift"], true],
    [["cmd", "alt"], ["cmd", "alt", "ctrl"], false],
    [["cmd", "alt"], ["cmd", "shift"], false],
    [["cmd", "alt", "shift"], ["cmd", "alt"], false],
    [["cmd", "alt", "shift"], ["cmd", "alt", "shift"], true],
  ];
  for (const [chord, flags, visible] of cases) {
    const f = fixture(chord);
    f.flags(flags);
    assert.equal(f.canvases[0]?.showing ?? false, visible, JSON.stringify([chord, flags]));
    f.overlay.stop();
  }
});

test("overlay stays while Shift comes and goes and redraws a reordered list at once", () => {
  const f = fixture();
  f.state.desktop!.slots = [listed(10, 1, "First"), listed(20, 2, "Second")];
  f.flags(["cmd", "alt"]);
  const canvas = f.canvases[0]!;
  const apps = () =>
    canvas.elements.map((e) => e.text).filter((t) => t === "First" || t === "Second");
  // The focus highlight is drawn just before the focused window's number and name.
  const highlighted = () => {
    const index = canvas.elements.findIndex((e) => e.roundedRectRadii?.xRadius === 7);
    return canvas.elements[index + 2]?.text;
  };
  assert.deepEqual([apps(), highlighted()], [["First", "Second"], "First"]);
  f.flags(["cmd", "alt", "shift"]);
  f.state.desktop!.slots.reverse();
  f.redraw();
  assert.deepEqual([canvas.showing, canvas.shows], [true, 2]);
  assert.deepEqual([apps(), highlighted()], [["Second", "First"], "First"]);
  f.flags(["cmd", "alt"]);
  assert.equal(canvas.showing, true);
  f.flags(["cmd"]);
  assert.equal(canvas.showing, false);
  f.overlay.stop();
});

test("overlay dims hidden and minimized windows and redraws when one is revealed", () => {
  const f = fixture();
  f.state.desktop!.slots = [listed(10, 1, "First"), {...listed(20, 2, "Second"), visible: false}];
  f.flags(["cmd", "alt"]);
  const canvas = f.canvases[0]!;
  assert.deepEqual(rows(canvas), [
    ["1", 1],
    ["First", 1],
    ["2", 0.45],
    ["Second", 0.45],
  ]);
  (f.state.desktop!.slots[1] as ListedWindow).visible = true;
  f.redraw();
  assert.equal(canvas.shows, 2);
  assert.deepEqual(rows(canvas).slice(2), [
    ["2", 1],
    ["Second", 1],
  ]);
  f.overlay.stop();
});

test("overlay keeps a waiting slot's number, dims it, and shows a list that only waits", () => {
  const f = fixture();
  f.state.desktop!.slots = [{bundleID: "app.second", app: "Second"}, listed(10, 1, "First")];
  f.flags(["cmd", "alt"]);
  const canvas = f.canvases[0]!;
  assert.deepEqual(rows(canvas), [
    ["1", 0.45],
    ["Second", 0.45],
    ["2", 1],
    ["First", 1],
  ]);
  f.state.desktop!.slots = [{bundleID: "app.second", app: "Second"}];
  f.redraw();
  assert.deepEqual(
    [canvas.showing, rows(canvas)],
    [
      true,
      [
        ["1", 0.45],
        ["Second", 0.45],
      ],
    ],
  );
  f.state.desktop!.slots = [];
  f.redraw();
  assert.equal(canvas.showing, false);
  f.overlay.stop();
});

test("duplicate app names get their window titles as a second line", () => {
  const f = fixture();
  f.state.desktop!.slots = [listed(10, 1, "Editor", "Notes"), listed(10, 2, "Editor", "Plans")];
  f.flags(["cmd", "alt"]);
  const texts = f.canvases[0]!.elements.map((e) => e.text);
  assert.ok(texts.includes("Notes") && texts.includes("Plans"));
  f.overlay.stop();
});
