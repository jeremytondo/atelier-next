"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const {GroupStore, sameFrame} = require("./GroupStore.js");
const window = (id, space = "a") => ({id, pid:10, space, frame:{x:0,y:0,w:100,h:100}});
const snapshot = (windows, current = "a", order = ["a","b"]) => ({focused:2, targetDisplay:"screen",
  displays:[{id:"screen", current, spaces:order.map(id => ({id, fullscreen:false}))}], windows});

test("focused first; reconcile preserves order, removes departed members, appends arrivals", () => {
  const store = new GroupStore(), group = store.group(snapshot([window(1), window(2)]));
  assert.deepEqual(group.members.map(w=>w.id), [2,1]);
  store.reconcile(snapshot([window(3), window(1), window(2)]));
  assert.deepEqual(group.members.map(w=>w.id), [2,1,3]);
  store.reconcile(snapshot([window(1),window(3)]));
  assert.deepEqual(group.members.map(w=>w.id), [1,3]);
});
test("inactive observations do not erase a group; native reorder preserves identity", () => {
  const store = new GroupStore(), group = store.group(snapshot([window(1),window(2)]));
  store.reconcile(snapshot([], "b", ["b","a"]));
  assert.deepEqual(group.members.map(w=>w.id), [2,1]);
  assert.equal(store.current(snapshot([], "a", ["b","a"])), group);
  store.reconcile(snapshot([], "b", ["b"]));
  assert.equal(store.groups.size, 0);
});
test("PID reuse does not inherit a previous member's successful Fill", () => {
  const store = new GroupStore(), group = store.group(snapshot([window(2)]));
  group.members[0].filledFrame = window(2).frame;
  store.reconcile(snapshot([{...window(2),pid:20}]));
  assert.equal(group.members[0].filledFrame, null);
});
test("member reorder persists through reconcile and frame comparison tolerates rounding", () => {
  const store = new GroupStore(), group = store.group(snapshot([window(1),window(2)]));
  store.moveMember(group, 2, 1);
  store.reconcile(snapshot([window(2),window(1)]));
  assert.deepEqual(group.members.map(w=>w.id), [1,2]);
  assert.equal(sameFrame(window(1).frame, {...window(1).frame, w:101}), true);
  assert.equal(sameFrame(window(1).frame, {...window(1).frame, w:110}), false);
});
