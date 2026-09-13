"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const {QuickApps, normalizeQuickApps, parseShortcut} = require("./QuickApps.js");

test("config accepts app names, optional sizes and modifier/key aliases", () => {
  const apps = normalizeQuickApps([
    {app:" Calculator ", shortcut:"control-option-c"},
    {app:"com.example.Notes", shortcut:"cmd-shift-left-bracket", size:{width:900,height:650}},
  ]);
  assert.equal(apps[0].app, "Calculator");
  assert.deepEqual(apps[0].mods, ["ctrl","alt"]);
  assert.equal(apps[0].size, undefined);
  assert.equal(apps[1].key, "[");
  assert.deepEqual(apps[1].size, {width:900,height:650});
});
test("invalid and ambiguous config fails before binding", () => {
  for (const shortcut of ["c", "ctrl-", "ctrl-control-c", "hyper-c", "ctrl-option-nope"]) {
    assert.throws(() => parseShortcut(shortcut), /Invalid/);
  }
  assert.throws(() => normalizeQuickApps({}), /array/);
  assert.throws(() => normalizeQuickApps([{app:"",shortcut:"ctrl-c"}]), /app name/);
  for (const size of [{width:0,height:1}, {width:Infinity,height:1}, {width:900}, null]) {
    assert.throws(() => normalizeQuickApps([{app:"Notes",shortcut:"ctrl-n",size}]), /size/);
  }
  assert.throws(() => normalizeQuickApps([{app:"Notes",shortcut:"ctrl-n",sizes:{}}]), /Unknown/);
  assert.throws(() => normalizeQuickApps([
    {app:"One",shortcut:"ctrl-option-c"}, {app:"Two",shortcut:"alt-control-c"},
  ]), /Duplicate/);
});
test("resolution supplies bundle IDs for exclusion and sends only configured toggle options", async () => {
  const apps = new QuickApps([{app:"Calculator",shortcut:"ctrl-c"},
    {app:"Notes",shortcut:"ctrl-n",size:{width:900,height:650}}]);
  await apps.resolve(async (command, args) => {
    assert.equal(command, "quickResolve");
    return {name:args.app,bundleID:"com.example." + args.app};
  });
  assert.equal(apps.bundleIDs.has("com.example.Calculator"), true);
  const requests = [];
  const request = async (command,args) => { requests.push({command,args}); return {action:"shown"}; };
  await apps.toggle("Calculator", request);
  await apps.toggle("com.example.Notes", request);
  assert.deepEqual(requests, [
    {command:"quickToggle",args:{app:"com.example.Calculator"}},
    {command:"quickToggle",args:{app:"com.example.Notes",size:{width:900,height:650}}},
  ]);
  assert.throws(() => apps.toggle("Unconfigured",request), /not configured/);
});
test("missing apps and duplicate resolved app identities are rejected", async () => {
  const entries = [{app:"Notes",shortcut:"ctrl-n"},{app:"com.example.Notes",shortcut:"ctrl-m"}];
  const apps = new QuickApps(entries);
  await assert.rejects(apps.resolve(async () => { throw new Error("Application missing"); }), /missing/);
  await assert.rejects(apps.resolve(async () => ({bundleID:"com.example.Notes"})), /more than once/);
  assert.equal(apps.bundleIDs.size, 0);
});
test("existing Atelier shortcuts and macOS assignments cannot be shadowed", async () => {
  const apps = new QuickApps([{app:"Notes",shortcut:"option-command-g"}]);
  await apps.resolve(async () => ({bundleID:"notes"}));
  let bound = false;
  const bind = () => { bound = true; };
  assert.throws(() => apps.bind({getHotkeys:()=>[{mods:["cmd","alt"],key:"g"}],assignable:()=>true},bind,()=>{}), /unavailable/);
  assert.equal(bound, false);
  assert.throws(() => apps.bind({getHotkeys:()=>[],assignable:()=>false},bind,()=>{}), /unavailable/);
  let callback;
  apps.bind({getHotkeys:()=>[],assignable:()=>true}, (mods,key,fn) => { callback = fn; }, id => id);
  assert.equal(callback(), "notes");
});
