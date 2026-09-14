"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const fs = require("node:fs"), net = require("node:net");
const path = require("node:path"), {spawnSync} = require("node:child_process");
const {exchange} = require("./session.js");

async function fixture(t, receive) {
  const directory = fs.mkdtempSync("/tmp/ate40-session-test-");
  fs.chmodSync(directory, 0o700);
  const socketPath = directory + "/s";
  const clients = new Set();
  let calls = 0;
  const server = net.createServer(socket => {
    clients.add(socket); socket.on("error", () => {});
    socket.on("close", () => clients.delete(socket));
    socket.once("data", data => { calls++; receive(socket, JSON.parse(String(data))); });
  });
  await new Promise(resolve => server.listen(socketPath, resolve));
  t.after(async () => {
    for (const socket of clients) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(directory, {recursive: true});
  });
  return {socketPath, calls: () => calls};
}

test("prepared transport sends one request and accepts a fragmented response", async t => {
  const f = await fixture(t, (socket, request) => {
    assert.deepEqual(request, {arguments: ["create-ready", "/private/new", "auto", "--disposable-session"]});
    socket.write('{"status":"native-entry-');
    setImmediate(() => socket.end('confirmed","createdID":"41"}\n'));
  });
  assert.equal((await exchange(f.socketPath, ["create-ready", "/private/new", "auto", "--disposable-session"])).createdID, "41");
  assert.equal(f.calls(), 1);
});

for (const mode of ["timeout", "disconnect", "malformed", "oversized"]) {
  test("prepared transport never retries after " + mode, async t => {
    const f = await fixture(t, socket => {
      if (mode === "disconnect") socket.end();
      if (mode === "malformed") socket.end("not JSON\n");
      if (mode === "oversized") socket.end("x".repeat(8 * 1024 * 1024 + 1));
    });
    await assert.rejects(exchange(f.socketPath, ["create-ready"], mode === "timeout" ? 30 : 2000));
    assert.equal(f.calls(), 1);
  });
}

for (const mode of ["build failure", "exit before ready"]) {
  test("preparation preserves launch evidence and clears an unusable session after " + mode, t => {
    const workspace = fs.mkdtempSync("/tmp/ate40-prepare-test-");
    t.after(() => fs.rmSync(workspace, {recursive: true}));
    const prototype = path.join(workspace, "Prototypes/WMBridge");
    for (const directory of [prototype, path.join(workspace, "App")]) {
      fs.mkdirSync(path.join(directory, "Sources"), {recursive: true, mode: 0o700});
      fs.writeFileSync(path.join(directory, "Package.swift"), "// test source fingerprint\n");
    }
    fs.copyFileSync(path.join(__dirname, "session.js"), path.join(prototype, "session.js"));
    const bin = path.join(workspace, "bin"); fs.mkdirSync(bin, {mode: 0o700});
    const script = mode === "build failure"
      ? '#!/bin/sh\nprintf \'%s\\n\' \'{"didError":true,"data":{"artifacts":{}}}\'\nexit 2\n'
      : '#!/bin/sh\nprintf \'{"didError":false,"data":{"artifacts":{"processId":%s}}}\\n\' "$$"\n';
    fs.writeFileSync(path.join(bin, "xcodebuildmcp"), script, {mode: 0o700});
    const result = spawnSync(process.execPath, [path.join(prototype, "session.js"), "prepare"],
      {encoding: "utf8", timeout: 5000, env: {...process.env, PATH: bin + ":" + process.env.PATH}});
    const directory = result.stderr?.match(/inspect (\/tmp\/atelier-ate40-[^/\s]+)\/launch\.json/)?.[1];
    if (directory) t.after(() => fs.rmSync(directory, {recursive: true}));
    assert.equal(result.status, 2, result.stderr);
    assert.ok(directory, result.stderr);
    assert.equal(fs.existsSync(path.join(workspace, ".build/ate-40-manual/prepared-helper.json")), false);
    const launch = JSON.parse(fs.readFileSync(path.join(directory, "launch.json")));
    assert.equal(launch.didError, mode === "build failure");
  });
}
