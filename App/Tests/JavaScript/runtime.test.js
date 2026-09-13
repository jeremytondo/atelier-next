"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {fakeHS} = require("./fakes.js");
const {Bridge} = require("../../Resources/Atelier/bridge.js");
const {create} = require("../../Resources/Atelier/index.js");
const {normalize, shortcut} = require("../../Resources/Atelier/configuration.js");
const {Groups} = require("../../Resources/Atelier/groups.js");
const {frameFor} = require("../../Resources/Atelier/overlay.js");
const options = {overlay:false, quickApps:[]};
const host = {helper:"/bundle/helper",bundleID:"atelier",version:"test"};

test("custom bindings replace defaults, support disabling, and detect aliases", () => {
  const config = normalize({...options, bindings:{"desktop-create":"ctrl-option-n", "select-1":"none"}});
  assert.equal(config.shortcuts.find(b => b.name === "desktop-create").key, "n");
  assert.ok(!config.shortcuts.some(b => b.name === "select-1"));
  assert.equal(shortcut("command-option-minus").identity, shortcut("alt-cmd--").identity);
  assert.throws(() => normalize({bindings:{"desktop-create":"alt-1"}}), /conflicts/);
  assert.throws(() => normalize({quickApps:[{app:"Calculator",shortcut:"cmd-alt-g"}]}), /conflicts/);
  assert.throws(() => normalize({quickApps:[{app:"A",shortcut:"cmd-a",size:{width:-1,height:20}}]}), /size/);
});
test("groups retain inactive membership, distinguish PID reuse, and exclude fullscreen", () => {
  const store = new Groups();
  const snap = {focused:2,targetDisplay:"D",displays:[{id:"D",current:"1",spaces:[{id:"1"},{id:"2",fullscreen:true}]}],windows:[1,2].map(id => ({id,pid:10,space:"1"}))};
  const group = store.repair(snap);
  assert.deepEqual(group.members.map(w => w.id), [2,1]);
  store.reconcile({...snap, displays:[{...snap.displays[0],current:"2"}],windows:[]});
  assert.equal(group.members.length, 2);
  store.reconcile({...snap, windows:[{id:1,pid:11,space:"1"},{id:2,pid:10,space:"1"}]});
  assert.deepEqual(group.members.map(w => [w.pid,w.id]), [[10,2],[11,1]]);
  assert.throws(() => store.repair({...snap,displays:[{...snap.displays[0],current:"2"}]}), /ordinary Desktop/);
});
test("overlay positions correctly on a screen above the primary", () => {
  assert.deepEqual(frameFor({x:0,y:-900,w:1200,h:900},{h:1000},320,200), {x:860,y:1020,w:320,h:200});
});
test("helper accepts fragmented replies and rejects pending work on malformed output", async () => {
  const {hs,state} = fakeHS(); let failure;
  const bridge = new Bridge(hs, "/helper", error => { failure = error; });
  await bridge.start(); state.replies = false;
  const first = bridge.request("snapshot"), id = state.requests.at(-1).id;
  const line = JSON.stringify({id,ok:true,result:{verified:true}}) + "\n";
  bridge.receive(line.slice(0,8)); bridge.receive(line.slice(8));
  assert.deepEqual(await first, {verified:true});
  const second = bridge.request("create");
  const rejected = assert.rejects(second, /Malformed/);
  bridge.receive("not json\n"); await rejected;
  assert.match(failure.message, /unknown/);
  assert.equal(state.tasks[0].isRunning, false);
});
test("helper timeout does not replay mutations and releases the process", async () => {
  const {hs,state} = fakeHS(); let failure;
  const bridge = new Bridge(hs, "/helper", error => { failure = error; });
  await bridge.start(); state.replies = false;
  const pending = bridge.request("delete");
  const rejected = assert.rejects(pending, /may have completed/);
  state.timers.at(-1).callback(); await rejected;
  assert.match(failure.message, /timed out/);
  assert.equal(state.requests.filter(r => r.command === "delete").length,1);
  assert.equal(state.tasks[0].isRunning,false);
});
test("startup failure cleans partially installed bindings", async () => {
  const {hs,state} = fakeHS(); state.failBinding = "g";
  const app = create(hs,host);
  await assert.rejects(app.start(options), /Shortcut unavailable/);
  assert.equal(app.state,"Stopped");
  assert.ok(state.keys.every(k => k.destroyed));
  assert.equal(state.tasks[0].isRunning,false);
});
test("pause/resume preserves configuration and releases all owned resources", async () => {
  const {hs,state} = fakeHS();
  const app = create(hs,host);
  await app.start({...options,bindings:{"desktop-create":"ctrl-option-n"}});
  assert.equal(app.state,"Running"); app.stop();
  assert.ok(state.keys.every(k => k.destroyed));
  assert.ok(state.timers.every(t => t.stopped));
  await app.start();
  assert.ok(state.keys.some(k => k.enabled && k.key === "n"));
  app.stop(); assert.ok(state.tasks.every(t => !t.isRunning));
});
test("cancelling startup cannot register shortcuts or stop a later session", async () => {
  const {hs,state} = fakeHS(); state.replies = false;
  const app = create(hs,host), pending = app.start(options);
  const rejected = assert.rejects(pending, /stopped/);
  app.stop(); await rejected;
  assert.equal(state.keys.length,0);
  state.replies = true; await app.start(options);
  state.tasks[0].ended(1,"old session");
  assert.equal(app.state,"Running"); app.stop();
});
test("Quick Apps keep absolute app references and exclude those apps from Groups", async () => {
  const {hs,state} = fakeHS();
  const app = create(hs,host), reference = "/tmp/Fixture.app";
  await app.start({overlay:false,quickApps:[{app:reference,shortcut:"cmd-shift-j",size:{width:700,height:500}}]});
  await app.quickApp(reference);
  const request = state.requests.find(r => r.command === "quickToggle");
  assert.equal(request.app,reference); assert.equal(request.expectedBundleID,"app."+reference);
  assert.deepEqual(request.size,{width:700,height:500}); app.stop();
});
test("missing Accessibility leaves defaults stopped without active shortcuts", async () => {
  const {hs,state} = fakeHS(); state.trusted = false;
  const app = create(hs,host);
  await assert.rejects(app.start(options), /Accessibility/);
  assert.equal(state.keys.length,0); assert.equal(state.tasks[0].isRunning,false);
});
test("grouping fills only the front member and selection focuses exact same-app windows", async () => {
  const {hs,state} = fakeHS(), fills = [];
  const application = {axElement:() => ({setAttributeValueValue:() => true})};
  const windows = [1,2].map(id => ({id,pid:42,application,frame:{x:0,y:0,w:400,h:300},
    axElement:() => ({setAttributeValueValue:() => true,performAction:() => { state.snapshot.focused = id; return true; }})}));
  application.allWindows = windows;
  hs.application.fromPID = () => application;
  hs.window.focusedWindow = () => windows.find(w => w.id === state.snapshot.focused);
  hs.ax.applicationElement = () => ({attributeValue:() => ({
    attributeValue:name => name === "AXIdentifier" ? "_zoomFill:" : null,
    children:() => [], isEnabled:true,
    performAction:() => { fills.push(state.snapshot.focused); return true; },
  })});
  state.snapshot.focused = 1;
  state.snapshot.windows = windows.map(w => ({id:w.id,pid:42,space:"1",app:"Fixture",bundleID:"fixture",frame:w.frame}));
  const app = create(hs,host); await app.start(options);
  await app.group(); assert.deepEqual(fills,[1]);
  await app.select(2); assert.equal(state.snapshot.focused,2); assert.deepEqual(fills,[1,2]);
  await app.select(2); assert.deepEqual(fills,[1,2]);
  app.stop();
});
test("overlapping Space actions are dropped and stop cannot reenable old bindings", async () => {
  const {hs,state} = fakeHS(), app = create(hs,host);
  await app.start(options); state.replies = false;
  const first = app.space("create"), rejected = assert.rejects(first, /stopped/);
  assert.deepEqual(await app.space("delete"),{busy:true});
  app.stop(); await rejected;
  assert.equal(state.requests.filter(r => r.command === "delete").length,0);
  assert.ok(state.keys.every(k => !k.enabled));
});
