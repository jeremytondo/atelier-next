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
    if (args[0] === "create-ready") return {status: "dock-registration-confirmed", createdID: "42"};
    if (args[0] === "create") return {status: "managed-type0-confirmed", createdID: "42"};
    return {status: "removed", createdID: "42"};
  }};
  return {root, calls, output, options, probe};
}

test("manual creation dispatches exactly once and leaves the returned ID for the user", async t => {
  const f = fixture(t);
  assert.equal(await main(["create"], f.options), 0);
  assert.deepEqual(f.calls.map(call => call[0]), ["create-ready"]);
  const directory = path.dirname(f.calls[0][1]);
  assert.deepEqual(f.calls[0], ["create-ready", path.join(directory, "creation"), "auto", "--disposable-session"]);
  assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
  assert.equal(fs.statSync(path.join(directory, "cli-result.json")).mode & 0o777, 0o600);
  assert.equal(JSON.parse(fs.readFileSync(path.join(directory, "cli-result.json"))).createdID, "42");
  assert.ok(f.output.some(line => line.includes("Space ID: 42")));
  assert.ok(f.output.some(line => line.includes("desktop:cleanup")));
});

test("native failure preserves evidence without retrying or cleaning up", async t => {
  const f = fixture(t, {"create-ready": async () => { throw new Error("watchdog expired; result unknown"); }});
  await assert.rejects(() => main(["create"], f.options), /watchdog expired/);
  assert.deepEqual(f.calls.map(call => call[0]), ["create-ready"]);
  const directory = path.dirname(f.calls[0][1]);
  assert.match(fs.readFileSync(path.join(directory, "cli-error.json"), "utf8"), /result unknown/);
  await assert.rejects(() => main(["create", directory], f.options), /EEXIST/);
  assert.equal(f.calls.length, 1);
});

test("uncertain creation returns failure while retaining the exact returned ID", async t => {
  const f = fixture(t, {"create-ready": () => ({status: "uncertain", createdID: "18446744073709551614"})});
  assert.equal(await main(["create"], f.options), 2);
  assert.deepEqual(f.calls.map(call => call[0]), ["create-ready"]);
  assert.ok(f.output.some(line => line.includes("18446744073709551614")));
});

test("native preflight refusal is preserved without a second invocation", async t => {
  const f = fixture(t, {"create-ready": () => { throw new Error("Creation requires exactly one screen"); }});
  await assert.rejects(() => main(["create"], f.options), /exactly one screen/);
  assert.deepEqual(f.calls.map(call => call[0]), ["create-ready"]);
  assert.equal(fs.existsSync(path.join(path.dirname(f.calls[0][1]), "cli-result.json")), false);
});

test("check and status without a trial are read only and allocate no trial", async t => {
  for (const args of [["create", "--check"], ["status"]]) {
    const f = fixture(t);
    assert.equal(await main(args, f.options), 0);
    assert.deepEqual(f.calls, [["probe"]]);
    assert.deepEqual(fs.readdirSync(f.root), []);
    assert.ok(f.output.includes("WMBridge creation API available: true"));
  }
});

test("inspection and cleanup target only the explicitly supplied trial", async t => {
  const f = fixture(t, {"cleanup-ready": () => ({status: "cleanup-refused", createdID: "42"})});
  assert.equal(await main(["status", f.root], f.options), 0);
  assert.equal(await main(["cleanup", f.root], f.options), 2);
  assert.deepEqual(f.calls, [["reconcile", path.join(f.root, "creation")],
    ["cleanup-ready", path.join(f.root, "creation"), "--disposable-session"]]);
  assert.equal(fs.readdirSync(f.root).length, 2);
});

test("missing cleanup target and invalid arguments never invoke the native helper", async t => {
  const f = fixture(t);
  for (const args of [["cleanup"], ["diagnose"], ["create", "--unknown"], ["status", "relative"], ["create", "/a", "extra"]]) {
    assert.equal(await main(args, f.options), 64);
  }
  assert.deepEqual(f.calls, []);
});

test("diagnosis is read only and preserves the saved-configuration disagreement", async t => {
  const f = fixture(t, {diagnose: () => ({returnedID: "42", savedSpaceIDs: ["1"], returnedIDInSavedConfiguration: false})});
  assert.equal(await main(["diagnose", f.root], f.options), 0);
  assert.deepEqual(f.calls, [["diagnose", path.join(f.root, "creation")]]);
  assert.ok(f.output.includes("Returned ID in saved configuration: false"));
  assert.ok(f.output.includes("This list does not establish Mission Control visibility."));
});

test("entry is explicit and raw creation remains independently runnable", async t => {
  const entry = fixture(t, {"create-ready": async () => ({status: "native-entry-confirmed", createdID: "42"})});
  assert.equal(await main(["create", "--enter"], entry.options), 0);
  assert.deepEqual(entry.calls.map(call => call[0]), ["create-ready"]);
  assert.deepEqual(entry.calls[0].slice(-2), ["--disposable-session", "--enter"]);
  const raw = fixture(t);
  assert.equal(await main(["create", "--raw"], raw.options), 0);
  assert.deepEqual(raw.calls.map(call => call[0]), ["create"]);
});

test("refresh, entry, and later observation failure cannot report success or retry", async t => {
  for (const status of ["created-refresh-unconfirmed", "dock-registration-confirmed", "native-entry-confirmed"]) {
    const f = fixture(t, {"create-ready": () => ({status, createdID: "42", error: "Destination not verified"})});
    assert.equal(await main(["create", "--enter"], f.options), 2);
    assert.deepEqual(f.calls.map(call => call[0]), ["create-ready"]);
    const saved = JSON.parse(fs.readFileSync(path.join(path.dirname(f.calls[0][1]), "cli-result.json")));
    assert.equal(saved.createdID, "42");
    assert.equal(saved.error, "Destination not verified");
  }
});

test("conflicting entry/raw and mutation flags on read-only commands are rejected", async t => {
  const f = fixture(t);
  for (const args of [["create", "--enter", "--raw"], ["create", "--check", "--enter"], ["status", "--enter"]]) {
    assert.equal(await main(args, f.options), 64);
  }
  assert.deepEqual(f.calls, []);
});
