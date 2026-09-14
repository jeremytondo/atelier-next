"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {Overlay} = require("../../Resources/Atelier/overlay.js");

// Records canvas lifetime and input events; does not simulate macOS placement.
function fixture() {
  const canvases = [], screen = {uuid:"D", frame:{x:0,y:0,w:1200,h:800}, fullFrame:{x:0,y:0,w:1200,h:800}};
  let callback, removed = false;
  const hs = {
    screen:{primary:() => screen, all:() => [screen]},
    window:{focusedWindow:() => ({pid:10,id:1})},
    eventtap:{eventTypes:{flagsChanged:1,keyDown:2,keyUp:3,leftMouseDown:4}, emit:{},
      addWatcher:(_, handler) => { callback = handler; return {start() {}}; },
      removeWatcher:() => { removed = true; }},
    canvas:{create:frame => {
      const canvas = {frame, showing:false, destroyed:false, shows:0,
        level() { return this; }, behaviorList() { return this; },
        clickActivating() { return this; }, ignoreMouseEvents() { return this; },
        setFrame(value) { this.frame = value; return this; },
        replaceElements(value) { this.elements = value; return this; },
        show() { assert.equal(this.destroyed,false); this.showing = true; this.shows++; return this; },
        hide() { this.showing = false; }, destroy() { this.destroyed = true; this.showing = false; }};
      canvases.push(canvas); return canvas;
    }},
  };
  const state = {snapshot:{missionControl:false}, group:{display:"D",space:"2",members:[{pid:10,id:1,app:"Fixture",title:"Saved window"}]}};
  const redraw = () => overlay.update(state.snapshot,state.group);
  const overlay = new Overlay(hs,["cmd","alt"],redraw);
  overlay.start();
  return {state,canvases,overlay,redraw,removed:() => removed,
    flags:flags => assert.equal(callback({flags}),hs.eventtap.emit)};
}

test("overlay replaces its native window when the group moves between Spaces or displays", () => {
  const f = fixture();
  f.flags(["cmd","alt"]);
  const first = f.canvases[0];
  f.redraw();
  assert.equal(first.shows,1);
  // Keep identical content and focus to exercise placement independently of drawing.
  for (const [display,space] of [["D","3"],["D","2"],["Main","2"]]) {
    const previous = f.canvases.at(-1);
    f.state.group = {...f.state.group,display,space};
    f.redraw();
    assert.equal(previous.destroyed,true);
    assert.notEqual(f.canvases.at(-1),previous);
    assert.equal(f.canvases.at(-1).showing,true);
  }
  f.overlay.stop();
  assert.ok(f.canvases.every(c => c.destroyed));
  assert.equal(f.removed(),true);
});

test("overlay shows the second group after releasing modifiers on the first Desktop", () => {
  const f = fixture();
  f.flags(["cmd","alt"]);
  f.flags([]);
  assert.equal(f.canvases[0].showing,false);
  f.state.group = {...f.state.group,space:"3",members:[{pid:20,id:2,app:"Second app",title:"Second window"}]};
  f.flags(["cmd","alt"]);
  assert.equal(f.canvases[0].destroyed,true);
  assert.equal(f.canvases.at(-1).showing,true);
  assert.ok(f.canvases.at(-1).elements.some(e => e.text === "Second app"));
  f.flags([]);
  assert.equal(f.canvases.at(-1).showing,false);
  f.overlay.stop();
});

test("overlay hides during Mission Control and on ungrouped Desktops, then shows again", () => {
  const f = fixture(), group = f.state.group;
  f.flags(["cmd","alt"]);
  f.state.snapshot.missionControl = true;
  f.redraw();
  assert.equal(f.canvases.at(-1).showing,false);
  f.state.snapshot.missionControl = false;
  f.redraw();
  assert.equal(f.canvases.at(-1).showing,true);
  f.state.group = null;
  f.redraw();
  assert.equal(f.canvases.at(-1).showing,false);
  f.state.group = group;
  f.redraw();
  assert.equal(f.canvases.at(-1).showing,true);
  f.overlay.stop();
});
