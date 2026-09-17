import assert from "node:assert/strict";
import {test} from "node:test";
import type {HS} from "../api/hs.ts";
import {createAPI} from "../api/index.ts";
import {
  type Credentials,
  type DispatchResponse,
  dispatch,
  dispatchPath,
  dispatchPort,
  dispatchVersion,
  serve,
} from "../defaults/dispatch.ts";
import {createDefaults} from "../defaults/index.ts";
import {parse} from "../defaults/state.ts";
import {type FakeServer, type FakeState, fakeApp, fakeHS} from "./fakes.ts";

const options = {overlay: false, quickApps: []};
const path = "/Users/fake/Library/Application Support/Atelier/windows.json";
const credentialsFile = "/Users/fake/Library/Application Support/Atelier/companion.json";
const reload = {version: dispatchVersion, action: "reload-config"};
function session(hs: HS) {
  const api = createAPI(hs, {
    providers: "/Applications/Atelier.app/Contents/MacOS/atelier-providers",
  });
  return createDefaults(hs, api, {expectedBuild: "133.1", version: "test"});
}
const savedIDs = (state: FakeState) => parse(state.files[path]!)![0]!.windows.map((w) => w.id);
/** The session's server, which must be the only one, on the port its credentials name. */
function serving(state: FakeState): {server: FakeServer; credentials: Credentials} {
  const server = state.servers.at(-1);
  assert.ok(server?.running, "the session is not serving");
  assert.equal(server.interface, "localhost");
  const written = state.files[credentialsFile];
  assert.ok(written, "the session wrote no credentials");
  const credentials = JSON.parse(written) as Credentials;
  assert.equal(credentials.version, dispatchVersion);
  assert.equal(credentials.port, server.port);
  assert.equal(server.port, dispatchPort);
  assert.match(credentials.secret, /^[0-9a-f]{64}$/);
  return {server, credentials};
}
/** What the companion does: one POST of the envelope with the secret it read. */
function post(state: FakeState, request: unknown, secret?: string) {
  const {server, credentials} = serving(state);
  const answer = server.callback!(
    "POST",
    dispatchPath,
    {authorization: "Bearer " + (secret ?? credentials.secret)},
    JSON.stringify(request),
  );
  return {status: answer.status, response: JSON.parse(answer.body) as DispatchResponse};
}
/** Fires the one-turn wait a reload takes before stopping the session. */
function turn(state: FakeState) {
  const pending = state.timers.filter((t) => !t.stopped && !t.repeats && t.seconds === 0);
  assert.equal(pending.length, 1, "expected exactly one deferred reload");
  pending[0]!.stopped = true;
  pending[0]!.callback();
}
function captured(run: () => void): string[] {
  const lines: string[] = [],
    original = console.log;
  console.log = (line: string) => lines.push(line);
  try {
    run();
  } finally {
    console.log = original;
  }
  return lines;
}

test("dispatch validates the envelope before consulting the table or the session", () => {
  const calls: Record<string, unknown>[] = [];
  const table = {
    echo: (parameters: Record<string, unknown>) => {
      calls.push(parameters);
      return {seen: parameters};
    },
    failing: () => {
      throw new Error("no");
    },
    empty: () => undefined,
  };
  const answer = (request: unknown, reason: string | null = null) =>
    dispatch(request, table, () => reason);
  const refused = (request: unknown, pattern: RegExp, reason: string | null = null) => {
    const response = answer(request, reason);
    assert.equal(response.ok, false);
    assert.equal(response.version, dispatchVersion);
    assert.match(response.ok ? "" : response.error, pattern);
  };
  refused(null, /object/);
  refused("reload-config", /object/);
  refused({action: "echo"}, /version undefined; expected 1/);
  refused({version: 2, action: "echo"}, /Unsupported dispatch version 2/);
  refused({version: 1}, /needs an action/);
  refused({version: 1, action: ""}, /needs an action/);
  refused({version: 1, action: "echo", parameters: []}, /parameters must be an object/);
  refused({version: 1, action: "echo", parameters: null}, /parameters must be an object/);
  refused({version: 1, action: "toString"}, /Unknown action: toString/);
  refused({version: 1, action: "constructor"}, /Unknown action/);
  refused({version: 1, action: "echo"}, /stopped/, "stopped");
  refused({version: 1, action: "failing"}, /^no$/);
  assert.deepEqual(calls, []);
  assert.deepEqual(answer({version: 1, action: "echo", parameters: {name: "Dev"}}), {
    version: 1,
    ok: true,
    result: {seen: {name: "Dev"}},
  });
  assert.deepEqual(answer({version: 1, action: "echo"}), {
    version: 1,
    ok: true,
    result: {seen: {}},
  });
  assert.deepEqual(answer({version: 1, action: "empty"}), {version: 1, ok: true, result: null});
});

test("serve answers only an authorised JSON POST to the dispatch path, with the envelope as JSON", () => {
  const seen: unknown[] = [];
  const handle = (request: unknown): DispatchResponse => {
    seen.push(request);
    return {version: 1, ok: true, result: {done: true}};
  };
  const secret = "s3cret";
  const bearer = {Authorization: "Bearer " + secret};
  const answer = (method: string, path: string, headers: Record<string, string>, body: string) => {
    const response = serve(method, path, headers, body, secret, handle);
    assert.deepEqual(response.headers, {"Content-Type": "application/json"});
    return {status: response.status, body: JSON.parse(response.body)};
  };
  assert.deepEqual(answer("POST", dispatchPath, bearer, JSON.stringify(reload)), {
    status: 200,
    body: {version: 1, ok: true, result: {done: true}},
  });
  // Header names arrive in whatever case the client and HS2 chose.
  assert.equal(answer("POST", dispatchPath, {authorization: "Bearer " + secret}, "{}").status, 200);
  assert.deepEqual(seen, [reload, {}]);
  // Nothing without the secret reaches the runtime, as a browser's simple request cannot carry it.
  for (const headers of [
    {},
    {"Content-Type": "text/plain", Origin: "https://example.invalid"},
    {Authorization: "Bearer " + secret + "x"},
    {Authorization: "Bearer " + secret.slice(1)},
    {Authorization: secret},
    {"X-Authorization": "Bearer " + secret},
  ]) {
    const unauthorised = answer("POST", dispatchPath, headers, JSON.stringify(reload));
    assert.equal(unauthorised.status, 401, JSON.stringify(headers));
    assert.deepEqual(unauthorised.body, {version: 1, ok: false, error: "Unauthorized"});
  }
  assert.equal(answer("GET", dispatchPath, bearer, "").status, 405);
  assert.equal(
    answer("OPTIONS", dispatchPath, {Origin: "https://example.invalid"}, "").status,
    405,
  );
  assert.equal(answer("POST", "/", bearer, JSON.stringify(reload)).status, 404);
  assert.equal(answer("POST", dispatchPath + "/x", bearer, "").status, 404);
  const malformed = answer("POST", dispatchPath, bearer, "{");
  assert.equal(malformed.status, 400);
  assert.match(malformed.body.error, /must be JSON/);
  assert.equal(seen.length, 2);
  const refusal = serve("POST", dispatchPath, bearer, "{}", secret, () => ({
    version: 1,
    ok: false,
    error: "no",
  }));
  assert.equal(refusal.status, 400);
  assert.deepEqual(JSON.parse(refusal.body), {version: 1, ok: false, error: "no"});
});

test("a stopped session serves nothing, leaves no credentials, and refuses a direct call without resuming", async () => {
  const {hs, state} = fakeHS();
  const app = session(hs);
  assert.deepEqual(state.servers, []);
  assert.equal(state.files[credentialsFile], undefined);
  assert.deepEqual(app.dispatch(reload), {
    version: 1,
    ok: false,
    error: "Atelier is not running (Paused)",
  });
  assert.equal(state.reloaded, undefined);
  assert.equal(state.tasks.length, 0);
  await app.start(options);
  const first = serving(state).credentials.secret;
  assert.deepEqual(app.status().companion, {port: dispatchPort});
  app.stop();
  assert.ok(state.servers.every((s) => !s.running));
  assert.equal(state.files[credentialsFile], undefined);
  assert.deepEqual(app.status().companion, {port: null});
  assert.deepEqual(app.dispatch(reload), {
    version: 1,
    ok: false,
    error: "Atelier is not running (Paused)",
  });
  assert.equal(state.reloaded, undefined);
  assert.equal(app.status().state, "Paused");
  // Each session has its own secret; an old one no longer opens the door.
  await app.start();
  const second = serving(state).credentials.secret;
  assert.notEqual(first, second);
  assert.equal(post(state, reload, first).status, 401);
  app.stop();
});

test("Spotlight reload and the shortcut share one operation: answer, then flush lists, release resources, and reload", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1, 2, 3]);
  const app = session(hs);
  await app.start(options);
  await app.windows.select(2);
  assert.equal(state.files[path], undefined);
  let answer: ReturnType<typeof post> | undefined;
  assert.deepEqual(
    captured(() => {
      answer = post(state, reload);
    }),
    [],
  );
  // The reply leaves first; the session is still there to send it.
  assert.deepEqual(answer, {status: 200, response: {version: 1, ok: true, result: null}});
  assert.equal(app.status().state, "Running");
  assert.equal(state.reloaded, undefined);
  // Until it goes, a second request is refused rather than accepted twice.
  assert.deepEqual(post(state, reload).response, {
    version: 1,
    ok: false,
    error: "Reload Config is already on its way",
  });
  turn(state);
  // Then the file, the resources, and finally the reload.
  assert.equal(state.reloaded, true);
  assert.deepEqual(savedIDs(state), [1, 2, 3]);
  assert.equal(app.status().state, "Paused");
  assert.ok(state.keys.every((k) => k.destroyed));
  assert.ok(state.timers.every((t) => t.stopped));
  assert.ok(state.tasks.every((t) => !t.isRunning));
  assert.ok(state.servers.every((s) => !s.running));
  assert.equal(state.files[credentialsFile], undefined);
  // A direct call after the stop finds nothing running and changes nothing.
  state.reloaded = false;
  assert.equal(app.dispatch(reload).ok, false);
  assert.equal(state.reloaded, false);
});

test("repeated reloads from both entry points leave one set of resources each time", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1]);
  for (let round = 0; round < 3; round++) {
    // Each reload gives HS2 a fresh context; the package is required again there.
    const app = session(hs);
    await app.start(options);
    assert.equal(state.keys.filter((k) => k.enabled).length, state.keys.length / (round + 1));
    assert.equal(state.tasks.filter((t) => t.isRunning).length, 1);
    assert.equal(state.servers.filter((s) => s.running).length, 1);
    if (round % 2) {
      const key = state.keys.find((k) => k.key === "r" && k.enabled)!;
      key.callback();
      // The shortcut pressed twice schedules one reload.
      key.callback();
      for (let i = 0; i < 5; i++) await Promise.resolve();
    } else assert.equal(post(state, reload).status, 200);
    turn(state);
    assert.equal(state.reloaded, true);
    state.reloaded = false;
    assert.equal(state.keys.filter((k) => k.enabled).length, 0);
    assert.equal(state.tasks.filter((t) => t.isRunning).length, 0);
    assert.equal(state.timers.filter((t) => !t.stopped).length, 0);
    assert.equal(state.servers.filter((s) => s.running).length, 0);
  }
});

test("refused requests are one Console line: unknown actions, bad versions, and a busy session", async () => {
  const {hs, state} = fakeHS();
  fakeApp(hs, state, [1]);
  const app = session(hs);
  await app.start(options);
  let answer: ReturnType<typeof post> | undefined;
  assert.deepEqual(
    captured(() => {
      answer = post(state, {version: 1, action: "presets"});
    }),
    ["Atelier: Refused companion request: Unknown action: presets"],
  );
  assert.deepEqual(answer, {
    status: 400,
    response: {version: 1, ok: false, error: "Unknown action: presets"},
  });
  assert.deepEqual(
    captured(() => post(state, {action: "reload-config"})),
    ["Atelier: Refused companion request: Unsupported dispatch version undefined; expected 1"],
  );
  // An unauthorised request is not the session's business and leaves no line.
  assert.deepEqual(
    captured(() => assert.equal(post(state, reload, "guess").status, 401)),
    [],
  );
  state.replies = false;
  const pending = app.windows.select(1);
  assert.deepEqual(
    captured(() => post(state, reload)),
    ["Atelier: Refused companion request: Another command is still running"],
  );
  assert.equal(state.timers.filter((t) => !t.stopped && t.seconds === 0).length, 0);
  assert.equal(state.reloaded, undefined);
  assert.equal(app.status().state, "Running");
  assert.deepEqual(state.notifications, []);
  assert.deepEqual(state.dialogs, []);
  app.stop();
  await assert.rejects(pending);
});

test("credentials that cannot be written leave Atelier running without the companion", async () => {
  const {hs, state} = fakeHS();
  state.writable = false;
  const errors: string[] = [],
    original = console.error;
  console.error = (line: string) => errors.push(line);
  const app = session(hs);
  try {
    await app.start(options);
  } finally {
    console.error = original;
  }
  assert.equal(app.status().state, "Running");
  assert.deepEqual(app.status().companion, {port: null});
  assert.ok(state.servers.every((s) => !s.running));
  assert.deepEqual(errors, [
    "Atelier: Could not write " + credentialsFile + "; Spotlight actions are unavailable",
  ]);
  app.stop();
});
