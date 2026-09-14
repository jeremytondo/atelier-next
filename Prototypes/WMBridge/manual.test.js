"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {main} = require("./manual.js");

function fixture(t, overrides = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ate-40-manual-test-"));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const calls = [], output = [];
  const probe = {screens: [{name: "Test display"}], bridgeAnswered: true,
    bridgeMatchesCensus: true, createABIAvailable: 1,
    censusAfter: [{"Display Identifier": "A", "Current Space": {id64: 1}, Spaces: [{id64: 1, type: 0}]}]};
  const options = {root, log: line => output.push(line), invoke(args) {
    calls.push(args);
    if (overrides[args[0]]) return overrides[args[0]](args);
    if (args[0] === "probe") return probe;
    if (args[0] === "create") return {status: "managed-type0-confirmed", createdID: "42"};
    return {status: "removed", createdID: "42"};
  }};
  return {root, calls, output, options, probe};
}

test("manual creation dispatches exactly once and leaves the returned ID for the user", t => {
  const f = fixture(t);
  assert.equal(main(["create"], f.options), 0);
  assert.deepEqual(f.calls.map(call => call[0]), ["probe", "create"]);
  const directory = path.dirname(f.calls[1][1]);
  assert.deepEqual(f.calls[1], ["create", path.join(directory, "creation"), "A", "--disposable-session"]);
  assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
  assert.equal(fs.statSync(path.join(directory, "cli-result.json")).mode & 0o777, 0o600);
  assert.equal(JSON.parse(fs.readFileSync(path.join(directory, "cli-result.json"))).createdID, "42");
  assert.ok(f.output.some(line => line.includes("Space ID: 42")));
  assert.ok(f.output.some(line => line.includes("desktop:cleanup")));
});

test("native failure preserves evidence without retrying or cleaning up", t => {
  const f = fixture(t, {create: () => { throw new Error("watchdog expired; result unknown"); }});
  assert.throws(() => main(["create"], f.options), /watchdog expired/);
  assert.deepEqual(f.calls.map(call => call[0]), ["probe", "create"]);
  const directory = path.dirname(f.calls[1][1]);
  assert.match(fs.readFileSync(path.join(directory, "cli-error.json"), "utf8"), /result unknown/);
  assert.throws(() => main(["create", directory], f.options), /EEXIST/);
  assert.equal(f.calls.length, 2);
});

test("uncertain creation returns failure while retaining the exact returned ID", t => {
  const f = fixture(t, {create: () => ({status: "uncertain", createdID: "18446744073709551614"})});
  assert.equal(main(["create"], f.options), 2);
  assert.deepEqual(f.calls.map(call => call[0]), ["probe", "create"]);
  assert.ok(f.output.some(line => line.includes("18446744073709551614")));
});

test("ambiguous displays and missing capability refuse before creation", t => {
  for (const failure of ["displays", "capability"]) {
    const f = fixture(t);
    if (failure === "displays") f.probe.censusAfter.push({...f.probe.censusAfter[0]});
    else f.probe.createABIAvailable = false;
    assert.throws(() => main(["create"], f.options));
    assert.deepEqual(f.calls.map(call => call[0]), ["probe"]);
  }
});

test("check and status without a trial are read only and allocate no trial", t => {
  for (const args of [["create", "--check"], ["status"]]) {
    const f = fixture(t);
    assert.equal(main(args, f.options), 0);
    assert.deepEqual(f.calls, [["probe"]]);
    assert.deepEqual(fs.readdirSync(f.root), []);
    assert.ok(f.output.includes("WMBridge creation API available: true"));
  }
});

test("inspection and cleanup target only the explicitly supplied trial", t => {
  const f = fixture(t, {cleanup: () => ({status: "cleanup-refused", createdID: "42"})});
  assert.equal(main(["status", f.root], f.options), 0);
  assert.equal(main(["cleanup", f.root], f.options), 2);
  assert.deepEqual(f.calls, [["reconcile", path.join(f.root, "creation")],
    ["cleanup", path.join(f.root, "creation"), "--disposable-session"]]);
  assert.equal(fs.readdirSync(f.root).length, 2);
});

test("missing cleanup target and invalid arguments never invoke the native helper", t => {
  const f = fixture(t);
  for (const args of [["cleanup"], ["diagnose"], ["create", "--unknown"], ["status", "relative"], ["create", "/a", "extra"]]) {
    assert.equal(main(args, f.options), 64);
  }
  assert.deepEqual(f.calls, []);
});

test("diagnosis is read only and preserves the saved-configuration disagreement", t => {
  const f = fixture(t, {diagnose: () => ({returnedID: "42", savedSpaceIDs: ["1"], returnedIDInSavedConfiguration: false})});
  assert.equal(main(["diagnose", f.root], f.options), 0);
  assert.deepEqual(f.calls, [["diagnose", path.join(f.root, "creation")]]);
  assert.ok(f.output.includes("Returned ID in saved configuration: false"));
  assert.ok(f.output.includes("This list does not establish Mission Control visibility."));
});
