"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const createAtelier = require("./atelier.js");

test("quick apps are excluded from Group snapshots and share the operation lock", async () => {
  const windows = [
    {id:1,pid:10,bundleID:"editor",space:"a"},
    {id:2,pid:20,bundleID:"calculator",space:"a"},
  ];
  const snapshot = {trusted:true, focused:1, targetDisplay:"screen",
    displays:[{id:"screen",current:"a",spaces:[{id:"a",fullscreen:false}]}], windows};
  let completeToggle, destroyed = 0;
  const timer = () => ({stop() {}});
  global.hs = {
    timer:{doAfter:timer,doEvery:timer},
    window:{allWindows:()=>[]}, ax:{addWatcher(){},removeWatcher(){}}, notify:{show(){}},
    hotkey:{getHotkeys:()=>[],assignable:()=>true,create:()=>({enable:()=>true,destroy(){destroyed++;}})},
    task:{create(path,args,onExit,env,receive) {
      const task = {start:()=>task,terminate(){},sendInput(line) {
        const request = JSON.parse(line);
        const reply = result => receive("stdout", JSON.stringify({id:request.id,ok:true,result}) + "\n");
        if (request.command === "quickResolve") reply({bundleID:"calculator",name:"Calculator"});
        else if (request.command === "quickToggle") completeToggle = () => reply({action:"shown"});
        else reply(snapshot);
      }};
      return task;
    }},
  };
  const atelier = createAtelier({helper:"test",bindSpaces:false,bindGroups:false,
    quickApps:[{app:"Calculator",shortcut:"ctrl-option-c"}]});
  try {
    await atelier.start();
    const filtered = await atelier.probe();
    assert.deepEqual(filtered.windows.map(w=>w.id),[1]);
    assert.deepEqual(atelier.store.group(filtered).members.map(w=>w.id),[1]);
    const first = atelier.quickApp("Calculator");
    assert.deepEqual(await atelier.quickApp("Calculator"),{busy:true});
    completeToggle();
    assert.deepEqual(await first,{action:"shown"});
  } finally { atelier.stop(); delete global.hs; }
  assert.equal(destroyed,1);
});

test("a switch returns before Fill settles, never double-presses, and caches only the settled frame", async () => {
  let now = 1000, focusedId = 1, frameWrites = 0;
  const realNow = Date.now; Date.now = () => now;
  const timers = [];
  const timer = (seconds, callback) => {
    const t = {at: now + seconds * 1000, callback, stopped: false, fired: false, stop() { this.stopped = true; }};
    timers.push(t); return t;
  };
  async function advance(ms) {
    const until = now + ms;
    for (;;) {
      const due = timers.filter(t => !t.stopped && !t.fired && t.at <= until).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      now = Math.max(now, due.at); due.fired = true; due.callback();
      await new Promise(resolve => setImmediate(resolve));
    }
    now = until;
  }
  const screen = {frame: {x: 0, y: 0, w: 1000, h: 800}};
  const padded = {x: 8, y: 8, w: 984, h: 784};
  const windows = [1, 2].map(id => {
    let current = {x: 50, y: 50, w: 400, h: 300};
    return {id, pid: 10, screen, application: {axElement: () => ({setAttributeValueValue: () => true})},
      get frame() { return current; },
      set frame(r) { frameWrites++; current = {x: r.x, y: r.y, w: r.w, h: r.h}; },
      animate(r) { current = r; },
      axElement: () => ({performAction: () => true,
        setAttributeValueValue(name) { if (name === "AXMain") focusedId = id; return true; }})};
  });
  const snapshot = () => ({trusted: true, focused: focusedId, targetDisplay: "screen", missionControl: false,
    displays: [{id: "screen", current: "a", spaces: [{id: "a", fullscreen: false}]}],
    windows: windows.map(w => ({id: w.id, pid: 10, bundleID: "editor", app: "Editor", title: "", space: "a", frame: w.frame}))});
  global.HSRect = class { constructor(x, y, w, h) { Object.assign(this, {x, y, w, h}); } };
  global.hs = {
    timer: {doAfter: timer, doEvery: () => ({stop() {}})},
    window: {allWindows: () => windows, focusedWindow: () => windows.find(w => w.id === focusedId)},
    application: {fromPID: () => ({allWindows: windows})},
    ax: {addWatcher() {}, removeWatcher() {}}, notify: {show() {}},
    hotkey: {getHotkeys: () => [], assignable: () => true, create: () => ({enable: () => true, destroy() {}})},
    task: {create(path, args, onExit, env, receive) {
      const task = {start: () => task, terminate() {}, sendInput(line) {
        const request = JSON.parse(line);
        receive("stdout", JSON.stringify({id: request.id, ok: true, result: snapshot()}) + "\n");
      }};
      return task;
    }},
  };
  const atelier = createAtelier({helper: "test", bindSpaces: false, bindGroups: false, fill: "padded"});
  try {
    await atelier.start();
    const group = await atelier.group();
    const first = group.members.find(m => m.id === 1);
    assert.equal(frameWrites, 1);
    assert.equal(first.filledFrame, null, "the switch returned while Fill was still settling");

    await atelier.select(1);
    assert.equal(frameWrites, 1, "no second Fill while the first is settling");

    await advance(400);
    assert.deepEqual(first.filledFrame, padded);

    // Window 2 animates through an intermediate frame after Fill is applied.
    const second = group.members.find(m => m.id === 2);
    await atelier.select(2);
    assert.equal(frameWrites, 2);
    const target = windows[1].frame;
    windows[1].animate({x: 30, y: 30, w: 600, h: 500});
    await advance(50);
    windows[1].animate(target);
    await advance(60);
    assert.equal(second.filledFrame, null, "an animating window is not cached mid-change");
    await advance(300);
    assert.deepEqual(second.filledFrame, padded);

    await atelier.select(1);
    assert.equal(frameWrites, 2, "a settled filled window is not filled again");
  } finally { atelier.stop(); delete global.hs; delete global.HSRect; Date.now = realNow; }
});

test("Group switches are not dropped while a background observe pass is running", async () => {
  let focusedId = 1, hold = false, poll = null;
  const queued = [];
  const screen = {frame: {x: 0, y: 0, w: 1000, h: 800}};
  const windows = [1, 2].map(id => ({id, pid: 10, screen, frame: {x: 50, y: 50, w: 400, h: 300},
    application: {axElement: () => ({setAttributeValueValue: () => true})},
    axElement: () => ({performAction: () => true,
      setAttributeValueValue(name) { if (name === "AXMain") focusedId = id; return true; }})}));
  const snapshot = () => ({trusted: true, focused: focusedId, targetDisplay: "screen", missionControl: false,
    displays: [{id: "screen", current: "a", spaces: [{id: "a", fullscreen: false}]}],
    windows: windows.map(w => ({id: w.id, pid: 10, bundleID: "editor", app: "Editor", title: "", space: "a", frame: w.frame}))});
  const flush = () => new Promise(resolve => setImmediate(resolve));
  global.HSRect = class { constructor(x, y, w, h) { Object.assign(this, {x, y, w, h}); } };
  global.hs = {
    timer: {doAfter: () => ({stop() {}}), doEvery: (seconds, callback) => { poll = callback; return {stop() {}}; }},
    window: {allWindows: () => windows, focusedWindow: () => windows.find(w => w.id === focusedId)},
    application: {fromPID: () => ({allWindows: windows})},
    ax: {addWatcher() {}, removeWatcher() {}}, notify: {show() {}},
    hotkey: {getHotkeys: () => [], assignable: () => true, create: () => ({enable: () => true, destroy() {}})},
    task: {create(path, args, onExit, env, receive) {
      const task = {start: () => task, terminate() {}, sendInput(line) {
        const request = JSON.parse(line);
        const reply = () => receive("stdout", JSON.stringify({id: request.id, ok: true, result: snapshot()}) + "\n");
        if (hold) queued.push(reply); else reply();
      }};
      return task;
    }},
  };
  const atelier = createAtelier({helper: "test", bindSpaces: false, bindGroups: false, fill: "padded"});
  try {
    await atelier.start();
    await atelier.group();
    hold = true;
    poll();
    assert.equal(queued.length, 1, "the observe pass is waiting on its snapshot");
    const switched = atelier.select(2);
    await flush();
    assert.equal(queued.length, 2, "the switch was not dropped; it is waiting behind the observe snapshot");
    hold = false;
    while (queued.length) { queued.shift()(); await flush(); }
    assert.deepEqual(await switched, {window: 2});
    assert.equal(focusedId, 2);
    assert.deepEqual(atelier.metrics.filter(m => m.command.startsWith("dropped:")), []);
  } finally { atelier.stop(); delete global.hs; delete global.HSRect; }
});
