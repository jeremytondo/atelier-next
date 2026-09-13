"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const GroupOverlay = require("./GroupOverlay.js");
const {GroupStore} = require("./GroupStore.js");

function fixture() {
  let listener, focused = {id:2, pid:20};
  let requests = 0, removed = false;
  const screen = {uuid:"DISPLAY", frame:{x:0,y:25,w:1440,h:815}, fullFrame:{h:900}};
  const canvas = {visible:false, elements:[], destroyed:false,
    level() { return this; }, behaviorList() { return this; },
    clickActivating(value) { this.activates = value; return this; },
    ignoreMouseEvents(value) { this.passthrough = value; return this; },
    setFrame(value) { this.rect = value; return this; },
    replaceElements(value) { this.elements = value; return this; },
    show() { this.visible = true; return this; },
    hide() { this.visible = false; }, destroy() { this.destroyed = true; this.visible = false; }};
  const hs = {
    eventtap:{eventTypes:{flagsChanged:12,keyDown:10,keyUp:11,leftMouseDown:1,rightMouseDown:3}, emit:true,
      // Reproduce the installed HS2 runtime: this query stays empty during holds.
      currentModifiers:() => [],
      addWatcher(types, callback, listenOnly) {
        assert.deepEqual(types, [12,10,11,1,3]); assert.equal(listenOnly, true);
        listener = callback; return {start() {}};
      }, removeWatcher() { removed = true; }},
    screen:{primary:() => screen, all:() => [screen]},
    window:{focusedWindow:() => focused}, canvas:{create:() => canvas}
  };
  const overlay = new GroupOverlay(hs, () => requests++);
  const snapshot = {targetDisplay:"DISPLAY", focused:2, missionControl:false,
    displays:[{id:"DISPLAY", current:"1", spaces:[{id:"1", fullscreen:false}, {id:"2", fullscreen:false}]}],
    windows:[{id:1,pid:10,space:"1",app:"Browser",title:"First"},
      {id:2,pid:20,space:"1",app:"Editor",title:"Code"},
      {id:3,pid:10,space:"1",app:"Browser",title:"Second"}]};
  const store = new GroupStore(); store.group(snapshot);
  overlay.start();
  return {overlay, canvas, snapshot, store,
    update() { overlay.update(snapshot, store.current(snapshot)); },
    press(flags) { assert.equal(listener({flags}), true); },
    focus:value => { focused = value; },
    state:() => ({requests, removed})};
}

test("modifier chord reveals Group ordering, duplicates, and focus without intercepting input", () => {
  const f = fixture();
  f.press(["cmd", "leftCmd"]); f.update(); assert.equal(f.canvas.visible, false);
  f.press(["cmd", "leftCmd", "alt", "rightAlt"]); f.update();
  assert.equal(f.canvas.visible, true);
  assert.equal(f.canvas.activates, false); assert.equal(f.canvas.passthrough, true);
  const labels = f.canvas.elements.filter(e => e.type === "text").map(e => e.text);
  assert.deepEqual(labels.slice(2), ["1", "Editor", "2", "Browser", "First", "3", "Browser", "Second"]);
  assert.equal(f.canvas.elements.filter(e => e.fillColor?.blue === 0.9).length, 1);
  for (const element of f.canvas.elements.filter(e => e.type === "text")) {
    assert.equal(element.textColor.red, 1);
    assert.equal(element.textColor.green, 1);
    assert.equal(element.textColor.blue, 1);
  }
  assert.deepEqual(f.canvas.rect, {x:1100, y:80, w:320, h:202});
  f.press(["cmd", "alt", "shift"]); assert.equal(f.canvas.visible, false);
  f.press(["cmd", "alt"]); f.update(); assert.equal(f.canvas.visible, true);
  f.press(["alt"]); assert.equal(f.canvas.visible, false);
});

test("late snapshots cannot show after release; later input resynchronizes missed releases", () => {
  const f = fixture();
  f.press(["cmd", "alt"]); f.press([]); f.update();
  assert.equal(f.canvas.visible, false);
  f.press(["cmd", "alt"]); f.update();
  // The same callback also receives key and mouse events with current flags.
  f.press([]); assert.equal(f.canvas.visible, false);
});

test("ungrouped Spaces and Mission Control hide the panel while the chord remains held", () => {
  const f = fixture();
  f.press(["cmd", "alt"]); f.update(); assert.equal(f.canvas.visible, true);
  f.snapshot.missionControl = true; f.update(); assert.equal(f.canvas.visible, false);
  f.snapshot.missionControl = false; f.update(); assert.equal(f.canvas.visible, true);
  f.snapshot.displays[0].current = "2"; f.update(); assert.equal(f.canvas.visible, false);
});

test("tenth member matches the 0 shortcut; reordering is reflected; stop releases resources", () => {
  const f = fixture();
  const group = f.store.current(f.snapshot);
  for (let id = 4; id <= 11; id++) group.members.push({id,pid:id,app:"App " + id});
  f.press(["cmd", "alt"]); f.update();
  assert.ok(f.canvas.elements.some(e => e.text === "0"));
  assert.ok(f.canvas.elements.some(e => e.text === "11" && e.textColor.alpha === 0.45));
  f.store.moveMember(group, 2, 1); f.update();
  assert.equal(f.canvas.elements.filter(e => e.type === "text")[3].text, "Browser");
  f.overlay.stop(); f.update(); assert.equal(f.canvas.visible, false);
  assert.equal(f.canvas.destroyed, true);
  assert.deepEqual(f.state(), {requests:1, removed:true});
});

test("AppKit placement handles displays above, below, and left of primary", () => {
  assert.deepEqual(GroupOverlay.panelFrame({x:-1440,y:-900,w:1440,h:850},900,320,202),
    {x:-340,y:970,w:320,h:202});
  assert.deepEqual(GroupOverlay.panelFrame({x:0,y:900,w:1440,h:850},900,320,202),
    {x:1100,y:-830,w:320,h:202});
});
