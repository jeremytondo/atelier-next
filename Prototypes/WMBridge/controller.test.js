"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {TrialController} = require("./controller.js");
const {Bridge} = require("../../App/Resources/Atelier/bridge.js");
const {fakeHS} = require("../../App/Tests/JavaScript/fakes.js");
function peer(overrides = {}) {
  const requests = [];
  return {requests,async request(command, args) {
    requests.push({command,args});
    if (overrides[command]) return overrides[command](args);
    if (command === "wmbridgeProbe") return {bridgeAnswered:true,bridgeMatchesCensus:true,createABIAvailable:true};
    if (command === "snapshot") return {targetDisplay:"A",displays:[{id:"A",current:"1",spaces:[{id:"1"},{id:"2"}]}]};
    if (command === "wmbridgeCreate") return {status:"managed-type0-confirmed",createdID:"2"};
    return {displays:[{id:"A",current:"2"}]};
  }};
}
test("missing capability refuses before mutation", async () => {
  const bridge = peer({wmbridgeProbe:() => ({bridgeAnswered:false})});
  await assert.rejects(new TrialController(bridge).create("/private/run"), /unavailable/);
  assert.deepEqual(bridge.requests.map(r=>r.command),["wmbridgeProbe"]);
});
test("busy input and unknown helper outcome cannot replay creation", async () => {
  let fail;
  const bridge = peer({wmbridgeCreate:() => new Promise((_,reject)=>{ fail=reject; })});
  const controller = new TrialController(bridge), pending = controller.create("/private/run");
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(await controller.create("/private/run"),{busy:true});
  fail(new Error("Helper timed out; mutation may have completed"));
  await assert.rejects(pending,/may have completed/);
  await assert.rejects(controller.create("/private/run"),/never replays/);
  assert.equal(bridge.requests.filter(r=>r.command==="wmbridgeCreate").length,1);
});
test("creation remains successful evidence when activation fails", async () => {
  const bridge = peer({switch:() => { throw new Error("Shortcut timed out"); }});
  const result = await new TrialController(bridge).create("/private/run",true);
  assert.equal(result.createdID,"2"); assert.equal(result.status,"managed-type0-confirmed");
  assert.equal(result.activation,"failed-or-uncertain");
});
test("unconfirmed creation never activates", async () => {
  const bridge = peer({wmbridgeCreate:() => ({status:"uncertain",createdID:"2"})});
  const result = await new TrialController(bridge).create("/private/run",true);
  assert.equal(result.createdID,"2"); assert.equal(bridge.requests.some(r=>r.command==="switch"),false);
});
test("real Bridge timeout and restart do not replay an experiment mutation", async () => {
  const {hs,state} = fakeHS(), bridge = new Bridge(hs,"/experiment",()=>{});
  await bridge.start(); state.replies=false;
  const pending = bridge.request("wmbridgeCreate",{runDirectory:"/private/run"});
  const rejected = assert.rejects(pending,/may have completed/);
  state.timers.at(-1).callback(); await rejected;
  state.replies=true; await bridge.start();
  assert.equal(state.requests.filter(r=>r.command==="wmbridgeCreate").length,1);
  bridge.stop();
});
