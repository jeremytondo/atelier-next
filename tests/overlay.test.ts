import assert from "node:assert/strict";
import {test} from "node:test";
import type {HS} from "../api/hs.ts";
import type {Group} from "../defaults/groups.ts";
import {frameFor, Overlay} from "../defaults/overlay.ts";

interface Element {
  text?: string;
  roundedRectRadii?: {xRadius: number};
  textColor?: {alpha: number};
}

interface FakeCanvas {
  frame: unknown;
  showing: boolean;
  destroyed: boolean;
  shows: number;
  elements: Element[];
  level(): FakeCanvas;
  behaviorList(): FakeCanvas;
  clickActivating(): FakeCanvas;
  ignoreMouseEvents(): FakeCanvas;
  setFrame(value: unknown): FakeCanvas;
  replaceElements(value: Element[]): FakeCanvas;
  show(): FakeCanvas;
  hide(): void;
  destroy(): void;
}

// Records canvas lifetime and input events; does not simulate macOS placement.
function fixture(chord = ["cmd", "alt"]) {
  const canvases: FakeCanvas[] = [],
    screen = {
      uuid: "D",
      frame: {x: 0, y: 0, w: 1200, h: 800},
      fullFrame: {x: 0, y: 0, w: 1200, h: 800},
    };
  let callback: (event: {flags: string[]}) => unknown,
    removed = false;
  const hs = {
    screen: {primary: () => screen, all: () => [screen]},
    window: {focusedWindow: () => ({pid: 10, id: 1})},
    eventtap: {
      eventTypes: {flagsChanged: 1, keyDown: 2, keyUp: 3, leftMouseDown: 4},
      emit: {},
      addWatcher: (_: unknown, handler: typeof callback) => {
        callback = handler;
        return {start() {}};
      },
      removeWatcher: () => {
        removed = true;
      },
    },
    canvas: {
      create: (frame: unknown) => {
        const canvas: FakeCanvas = {
          frame,
          showing: false,
          destroyed: false,
          shows: 0,
          elements: [],
          level() {
            return this;
          },
          behaviorList() {
            return this;
          },
          clickActivating() {
            return this;
          },
          ignoreMouseEvents() {
            return this;
          },
          setFrame(value) {
            this.frame = value;
            return this;
          },
          replaceElements(value) {
            this.elements = value;
            return this;
          },
          show() {
            assert.equal(this.destroyed, false);
            this.showing = true;
            this.shows++;
            return this;
          },
          hide() {
            this.showing = false;
          },
          destroy() {
            this.destroyed = true;
            this.showing = false;
          },
        };
        canvases.push(canvas);
        return canvas;
      },
    },
  };
  const state: {snapshot: {missionControl: boolean}; group: Group | null} = {
    snapshot: {missionControl: false},
    group: {
      display: "D",
      space: "2",
      members: [{pid: 10, id: 1, app: "Fixture", title: "Saved window"}] as Group["members"],
      waiting: [],
    },
  };
  const redraw = () => overlay.update(state.snapshot, state.group);
  const overlay = new Overlay(hs as unknown as HS, chord, redraw);
  overlay.start();
  return {
    state,
    canvases,
    overlay,
    redraw,
    removed: () => removed,
    flags: (flags: string[]) => assert.equal(callback({flags}), hs.eventtap.emit),
  };
}

test("overlay positions correctly on a screen above the primary", () => {
  assert.deepEqual(frameFor({x: 0, y: -900, w: 1200, h: 900}, {h: 1000}, 320, 200), {
    x: 860,
    y: 1020,
    w: 320,
    h: 200,
  });
});

test("overlay replaces its native window when the group moves between Spaces or displays", () => {
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
    f.state.group = {...f.state.group!, display, space};
    f.redraw();
    assert.equal(previous.destroyed, true);
    assert.notEqual(f.canvases.at(-1), previous);
    assert.equal(f.canvases.at(-1)!.showing, true);
  }
  f.overlay.stop();
  assert.ok(f.canvases.every((c) => c.destroyed));
  assert.equal(f.removed(), true);
});

test("overlay shows the second group after releasing modifiers on the first Desktop", () => {
  const f = fixture();
  f.flags(["cmd", "alt"]);
  f.flags([]);
  assert.equal(f.canvases[0]!.showing, false);
  f.state.group = {
    ...f.state.group!,
    space: "3",
    members: [{pid: 20, id: 2, app: "Second app", title: "Second window"}] as Group["members"],
  };
  f.flags(["cmd", "alt"]);
  assert.equal(f.canvases[0]!.destroyed, true);
  assert.equal(f.canvases.at(-1)!.showing, true);
  assert.ok(f.canvases.at(-1)!.elements.some((e) => e.text === "Second app"));
  f.flags([]);
  assert.equal(f.canvases.at(-1)!.showing, false);
  f.overlay.stop();
});

test("overlay hides during Mission Control and on ungrouped Desktops, then shows again", () => {
  const f = fixture(),
    group = f.state.group;
  f.flags(["cmd", "alt"]);
  f.state.snapshot.missionControl = true;
  f.redraw();
  assert.equal(f.canvases.at(-1)!.showing, false);
  f.state.snapshot.missionControl = false;
  f.redraw();
  assert.equal(f.canvases.at(-1)!.showing, true);
  f.state.group = null;
  f.redraw();
  assert.equal(f.canvases.at(-1)!.showing, false);
  f.state.group = group;
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

test("overlay stays while Shift comes and goes and redraws a reordered Group at once", () => {
  const f = fixture();
  f.state.group!.members = [
    {pid: 10, id: 1, app: "First", title: ""},
    {pid: 20, id: 2, app: "Second", title: ""},
  ] as Group["members"];
  f.flags(["cmd", "alt"]);
  const canvas = f.canvases[0]!;
  const apps = () =>
    canvas.elements.map((e) => e.text).filter((t) => t === "First" || t === "Second");
  // The focus highlight is drawn just before the focused member's number and name.
  const highlighted = () => {
    const index = canvas.elements.findIndex((e) => e.roundedRectRadii?.xRadius === 7);
    return canvas.elements[index + 2]?.text;
  };
  assert.deepEqual([apps(), highlighted()], [["First", "Second"], "First"]);
  f.flags(["cmd", "alt", "shift"]);
  f.state.group!.members.reverse();
  f.redraw();
  assert.deepEqual([canvas.showing, canvas.shows], [true, 2]);
  assert.deepEqual([apps(), highlighted()], [["Second", "First"], "First"]);
  f.flags(["cmd", "alt"]);
  assert.equal(canvas.showing, true);
  f.flags(["cmd"]);
  assert.equal(canvas.showing, false);
  f.overlay.stop();
});

test("overlay keeps a waiting slot's number, dims it, and shows a Group that only waits", () => {
  const f = fixture();
  f.state.group!.members = [{pid: 10, id: 1, app: "First", title: ""}] as Group["members"];
  f.state.group!.waiting = [{bundleID: "app.second", app: "Second", position: 0}];
  f.flags(["cmd", "alt"]);
  const canvas = f.canvases[0]!;
  const rows = () =>
    canvas.elements
      .filter((e) => e.text && !/GROUP WINDOWS|Release/.test(e.text))
      .map((e) => [e.text, e.textColor?.alpha]);
  assert.deepEqual(rows(), [
    ["1", 0.45],
    ["Second", 0.45],
    ["2", 1],
    ["First", 1],
  ]);
  f.state.group!.members = [];
  f.redraw();
  assert.deepEqual(
    [canvas.showing, rows()],
    [
      true,
      [
        ["1", 0.45],
        ["Second", 0.45],
      ],
    ],
  );
  f.state.group!.waiting = [];
  f.redraw();
  assert.equal(canvas.showing, false);
  f.overlay.stop();
});
