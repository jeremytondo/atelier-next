import assert from "node:assert/strict";
import {test} from "node:test";
import {bundleIdentifier, providersPath} from "../api/bundle.ts";
import {Pipe} from "../api/pipe.ts";
import {fakeHS} from "./fakes.ts";

test("pipe accepts fragmented replies and rejects pending work on malformed output", async () => {
  const {hs, state} = fakeHS();
  let failure: Error | undefined;
  const pipe = new Pipe(hs, "/providers", (error) => {
    failure = error;
  });
  await pipe.start();
  state.replies = false;
  const first = pipe.request("spaces.snapshot"),
    id = state.requests.at(-1)!.id;
  const line = JSON.stringify({id, ok: true, result: {verified: true}}) + "\n";
  pipe.receive(line.slice(0, 8));
  pipe.receive(line.slice(8));
  assert.deepEqual(await first, {verified: true});
  const second = pipe.request("spaces.create");
  const rejected = assert.rejects(second, /Malformed/);
  pipe.receive("not json\n");
  await rejected;
  assert.match(failure!.message, /unknown/);
  assert.equal(state.tasks[0]!.isRunning, false);
});

test("pipe timeout does not replay mutations and releases the process", async () => {
  const {hs, state} = fakeHS();
  let failure: Error | undefined;
  const pipe = new Pipe(hs, "/providers", (error) => {
    failure = error;
  });
  await pipe.start();
  state.replies = false;
  const pending = pipe.request("spaces.delete");
  const rejected = assert.rejects(pending, /may have completed/);
  state.timers.at(-1)!.callback();
  await rejected;
  assert.match(failure!.message, /timed out/);
  assert.equal(state.requests.filter((r) => r.command === "spaces.delete").length, 1);
  assert.equal(state.tasks[0]!.isRunning, false);
});

test("pipe retries launch while the previous instance holds the lock", async () => {
  const {hs, state} = fakeHS();
  const failures: Error[] = [];
  const pipe = new Pipe(hs, "/providers", (error) => failures.push(error));
  state.lockedLaunches = 2;
  const started = pipe.start();
  // Each retry waits on a session timer; fire them as they appear.
  for (let n = 0; n < 2; n++) {
    await new Promise((resolve) => setImmediate(resolve));
    state.timers
      .filter((t) => !t.stopped)
      .at(-1)!
      .callback();
  }
  const hello = await started;
  assert.equal(hello.trusted, true);
  assert.equal(state.tasks.length, 3);
  assert.equal(state.tasks[2]!.isRunning, true);
  assert.deepEqual(failures, []);
  assert.equal(state.requests.filter((r) => r.command === "hello").length, 3);
  pipe.stop();
});

test("pipe reports an exit with any other status without retrying", async () => {
  const {hs, state} = fakeHS();
  const failures: Error[] = [];
  const pipe = new Pipe(hs, "/providers", (error) => failures.push(error));
  state.replies = false;
  const started = pipe.start();
  await new Promise((resolve) => setImmediate(resolve));
  state.tasks[0]!.ended(1, "exit");
  await assert.rejects(started, /exited before answering \(1\)/);
  assert.equal(state.tasks.length, 1);
  assert.deepEqual(failures, []);
});

test("pipe refuses a providers binary speaking another protocol version", async () => {
  const {hs, state} = fakeHS();
  const pipe = new Pipe(hs, "/providers", () => {});
  state.replies = false;
  const started = pipe.start();
  await new Promise((resolve) => setImmediate(resolve));
  const id = state.requests.at(-1)!.id;
  state.tasks[0]!.output(
    "stdout",
    JSON.stringify({id, ok: true, result: {protocolVersion: 2, trusted: true}}) + "\n",
  );
  await assert.rejects(started, /versions do not match/);
  assert.equal(state.tasks[0]!.isRunning, false);
});

test("the providers executable is found in Atelier.app, with Launch Services as the second look", async () => {
  const {hs, state} = fakeHS();
  const installed = "/Applications/Atelier.app/Contents/MacOS/atelier-providers";
  assert.throws(
    () => providersPath(hs),
    /Atelier\.app is not installed at \/Applications\/Atelier\.app; reinstall/,
  );
  state.registeredApps[bundleIdentifier] = "/Users/fake/Applications/Atelier.app";
  assert.throws(() => providersPath(hs), /not installed/);
  state.files["/Users/fake/Applications/Atelier.app/Contents/MacOS/atelier-providers"] = "";
  assert.equal(
    providersPath(hs),
    "/Users/fake/Applications/Atelier.app/Contents/MacOS/atelier-providers",
  );
  state.files[installed] = "";
  assert.equal(providersPath(hs), installed);
  // The pipe asks at each launch and reports a missing bundle as its own failure.
  delete state.files[installed];
  delete state.files["/Users/fake/Applications/Atelier.app/Contents/MacOS/atelier-providers"];
  const pipe = new Pipe(
    hs,
    () => providersPath(hs),
    () => {},
  );
  await assert.rejects(pipe.start(), /not installed/);
  assert.equal(state.tasks.length, 0);
  state.files[installed] = "";
  await pipe.start();
  assert.equal(state.tasks[0]!.path, installed);
  pipe.stop();
});
