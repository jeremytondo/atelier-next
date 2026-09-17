import assert from "node:assert/strict";
import {test} from "node:test";
import type {HS} from "../api/hs.ts";
import {createAPI} from "../api/index.ts";
import type {Options} from "../defaults/configuration.ts";
import {createDefaults} from "../defaults/index.ts";
import {feedbackSeconds} from "../defaults/leader.ts";
import {
  eventTypes,
  type FakeCanvas,
  type FakeState,
  fakeHS,
  fakeMenuBar,
  keycodeMap,
  keyEvent,
  windowMenu,
} from "./fakes.ts";

const base: Options = {overlay: false, quickApps: []};

/** Fires every zero-delay timer, then lets promises settle, until nothing is left. */
async function pump(state: FakeState) {
  for (let round = 0; round < 20; round++) {
    const due = state.timers.filter((t) => !t.stopped && !t.repeats && t.seconds === 0);
    for (const timer of due) {
      timer.stopped = true;
      timer.callback();
    }
    for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
    if (!state.timers.some((t) => !t.stopped && !t.repeats && t.seconds === 0)) break;
  }
}

/** A running session with the leader bound and the Window menu of a fake app in front. */
async function leaderSession(options: Options = {}, menuEnabled = true) {
  const {hs, state} = fakeHS();
  const bar = fakeMenuBar(hs, [windowMenu(menuEnabled)]);
  const api = createAPI(hs, {providers: "/share/atelier/atelier-providers"});
  const app = createDefaults(hs, api, {expectedBuild: "133.1", version: "test"});
  await app.start({...base, ...options});
  const tap = () => state.taps.find((t) => !t.listenOnly)!;
  const leaderKey = () => state.keys.find((k) => k.key === "space" && k.mods.includes("alt"))!;
  const canvas = (): FakeCanvas | undefined => state.canvases.at(-1);
  const texts = () =>
    canvas()
      ?.elements.map((e) => e.text)
      .filter((t) => t !== undefined) ?? [];
  const alpha = (text: string) => canvas()?.elements.find((e) => e.text === text)?.textColor?.alpha;
  const footer = () => texts().at(-1);
  const title = () => texts()[0];
  return {
    hs,
    state,
    bar,
    app,
    tap,
    canvas,
    texts,
    alpha,
    footer,
    title,
    /** Presses the leader chord through its hotkey and renders. */
    async enter() {
      leaderKey().callback();
      await pump(state);
    },
    /** A key down through the tap; returns whether the event reaches applications. */
    async press(key: string, flags: string[] = []) {
      const result = tap().callback(keyEvent(key, flags));
      await pump(state);
      return result;
    },
    async flags(flags: string[]) {
      return tap().callback({type: eventTypes.flagsChanged!, keyCode: 0, flags});
    },
    timer: (seconds: number) =>
      state.timers.find((t) => !t.stopped && !t.repeats && t.seconds === seconds),
  };
}

test("the leader shows the root menu at once, descends into Windows, and runs Fill", async () => {
  const f = await leaderSession();
  assert.equal(f.tap().running, false);
  await f.enter();
  assert.equal(f.tap().running, true);
  assert.deepEqual(f.app.status().leader, {shortcut: "⌥Space", active: true, path: []});
  assert.equal(f.title(), "ATELIER");
  // Bottom-right of the screen with keyboard focus, like the window list, and as tall as its rows.
  const frame = f.canvas()!.frame as {x: number; y: number; w: number; h: number};
  assert.deepEqual([frame.x + frame.w, frame.y, frame.w], [1180, 20, 320]);
  assert.equal(frame.h, 36 + 3 * 30 + 28);
  // Window-shaped corners and a hairline edge inside them, drawn under everything else.
  const [background, edge] = f.canvas()!.elements;
  assert.equal(background?.roundedRectRadii, 20);
  assert.deepEqual(
    [edge?.action, edge?.roundedRectRadii, edge?.strokeColor?.alpha],
    ["stroke", 19.5, 0.14],
  );
  // Quick Apps has nothing configured under it, so it is not offered.
  assert.deepEqual(
    f.texts().filter((t) => /Spaces|Windows|Quick Apps|Configuration/.test(t)),
    ["Spaces", "Windows", "Configuration"],
  );
  assert.equal(f.footer(), "");
  // Carbon sees the leader chord released only if its key-up gets through.
  assert.equal(f.tap().callback(keyEvent("space", ["alt"], eventTypes.keyUp)), true);
  assert.equal(await f.press("w"), false);
  assert.equal(f.tap().callback(keyEvent("w", [], eventTypes.keyUp)), true);
  assert.equal(f.title(), "WINDOWS");
  assert.ok(f.texts().includes("Fill"));
  assert.ok(f.texts().includes("fn⌃F"), "the native shortcut is shown");
  assert.ok(f.texts().includes("Arrange"));
  assert.equal(f.footer(), "");
  assert.deepEqual(f.app.status().leader?.path, ["W"]);
  assert.equal(await f.press("f"), false);
  assert.deepEqual(f.bar.pressed, ["_zoomFill::AXPress"]);
  assert.equal(f.app.status().leader?.active, false);
  assert.equal(f.tap().running, false);
  assert.ok(f.canvas()!.destroyed);
  // The keys were consumed; nothing reached the frontmost app through the tap.
  assert.equal(f.tap().callback(keyEvent("f")), true);
  f.app.stop();
  assert.ok(f.tap().removed);
});

test("unknown keys and unavailable commands keep the menu open with footer feedback", async () => {
  const f = await leaderSession({}, false);
  await f.enter();
  assert.equal(await f.press("x"), false);
  assert.equal(f.footer(), "No command for X");
  assert.equal(f.title(), "ATELIER");
  const rows = f.texts().length;
  f.timer(feedbackSeconds)!.callback();
  assert.equal(f.footer(), "");
  assert.equal(f.texts().length, rows);
  await f.press("w");
  assert.equal(f.alpha("Center"), 0.45);
  assert.equal(await f.press("c"), false);
  assert.equal(f.footer(), "Center is unavailable for the focused window");
  assert.equal(f.title(), "WINDOWS");
  assert.deepEqual(f.bar.pressed, []);
  await f.press("delete");
  assert.equal(f.title(), "ATELIER");
  assert.equal(await f.press("escape"), false);
  assert.equal(f.app.status().leader?.active, false);
  f.app.stop();
});

test("clicks and Cmd-Tab cancel leader mode and pass through", async () => {
  const f = await leaderSession();
  await f.enter();
  assert.equal(f.tap().callback({type: eventTypes.leftMouseDown!, keyCode: 0, flags: []}), true);
  assert.equal(f.app.status().leader?.active, false);
  await f.enter();
  assert.equal(await f.press("tab", ["cmd"]), true);
  assert.equal(f.app.status().leader?.active, false);
  assert.ok(f.canvas()!.destroyed);
  f.app.stop();
});

test("the leader's own modifiers are ignored until released, and the leader chord restarts", async () => {
  const f = await leaderSession();
  await f.enter();
  await f.press("w", ["alt"]);
  assert.equal(f.title(), "WINDOWS");
  await f.press("space", ["alt"]);
  assert.equal(f.title(), "ATELIER");
  await f.flags([]);
  await f.press("w", ["alt"]);
  assert.equal(f.footer(), "No command for ⌥W");
  // Fn arrives with arrow keys on Apple keyboards and does not change the chord.
  await f.press("escape");
  await f.enter();
  await f.press("s");
  await f.press("left", ["fn", "shift"]);
  assert.ok(f.state.requests.some((r) => r.command === "spaces.reorder"));
  f.app.stop();
});

test("the idle timeout resets on each key, can be disabled, and the HUD delay is honored", async () => {
  const f = await leaderSession({hud: {timeout: 10, delay: 0.5}});
  await f.enter();
  assert.equal(f.canvas(), undefined);
  const first = f.timer(10)!;
  await f.press("w");
  assert.equal(first.stopped, true);
  assert.notEqual(f.timer(10), undefined);
  assert.equal(f.canvas(), undefined);
  f.timer(0.5)!.callback();
  assert.equal(f.title(), "WINDOWS");
  f.timer(10)!.callback();
  assert.equal(f.app.status().leader?.active, false);
  // Before the delay, an unknown key reveals the HUD at once.
  await f.enter();
  await f.press("x");
  assert.equal(f.footer(), "No command for X");
  assert.equal(f.timer(0.5), undefined);
  f.app.stop();
  const g = await leaderSession({hud: {timeout: false}});
  await g.enter();
  assert.equal(g.timer(10), undefined);
  assert.ok(g.canvas()?.showing);
  g.app.stop();
});

test("custom commands, renamed menus, and disabled keys share the registry with the HUD", async () => {
  let ran = 0,
    reason: string | null = "Not now";
  const f = await leaderSession({
    commands: {
      hello: {label: "Say Hello", action: () => ran++, available: () => reason},
    },
    keymap: {
      global: {"cmd-shift-h": "hello", "cmd-option-1": false, "fn-ctrl-f": "window-fill"},
      leader: {x: {menu: "Extras"}, "x h": "hello", c: false, w: {menu: "Fenster"}},
    },
  });
  await f.enter();
  assert.ok(f.texts().includes("Extras") && f.texts().includes("Fenster"));
  assert.ok(!f.texts().includes("Configuration"));
  await f.press("x");
  assert.deepEqual(
    f.texts().filter((t) => /Say Hello|⇧⌘H/.test(t)),
    ["Say Hello", "⇧⌘H"],
  );
  assert.equal(f.alpha("Say Hello"), 0.45);
  await f.press("h");
  assert.equal(f.footer(), "Not now");
  assert.equal(ran, 0);
  reason = null;
  await f.press("h");
  assert.equal(ran, 1);
  assert.equal(f.app.status().leader?.active, false);
  // The global chord runs the same command, and reports instead of running when unavailable.
  const hotkey = f.state.keys.find((k) => k.key === "h")!;
  hotkey.callback();
  await pump(f.state);
  assert.equal(ran, 2);
  reason = "Busy elsewhere";
  hotkey.callback();
  await pump(f.state);
  assert.equal(ran, 2);
  assert.ok(f.state.notifications.includes("Busy elsewhere"));
  // A disabled chord is still registered so the key goes nowhere.
  const disabled = f.state.keys.find((k) => k.key === "1" && k.mods.includes("cmd"))!;
  assert.equal(disabled.enabled, true);
  disabled.callback();
  await pump(f.state);
  assert.equal(
    f.app.status().metrics.some((m) => m.name === "select"),
    false,
  );
  // Fn chords go through the event tap hotkeys and run native actions.
  assert.deepEqual(
    f.state.eventHotkeys.map((k) => [k.mods, k.key]),
    [[["fn", "ctrl"], "f"]],
  );
  f.state.eventHotkeys[0]!.callback();
  await pump(f.state);
  assert.deepEqual(f.bar.pressed, ["_zoomFill::AXPress"]);
  // A user command at a shipped prefix replaces the whole submenu.
  const g = await leaderSession({keymap: {leader: {w: "console"}}});
  await g.enter();
  assert.deepEqual(
    g.texts().filter((t) => /Windows|Hammerspoon Console/.test(t)),
    ["Hammerspoon Console"],
  );
  await g.press("w");
  assert.equal(g.state.consoleOpened, true);
  g.app.stop();
  f.app.stop();
  assert.ok(f.state.eventHotkeys.every((k) => k.removed));
});

test("global failures and throwing availability checks are reported, not swallowed", async () => {
  const f = await leaderSession({
    commands: {
      broken: {
        label: "Broken",
        action: () => {},
        available: () => {
          throw new Error("availability exploded");
        },
      },
    },
    keymap: {global: {"cmd-shift-b": "broken", "cmd-shift-o": "open-config"}},
  });
  f.state.openURLResult = false;
  f.state.keys.find((k) => k.key === "o" && k.mods.includes("cmd"))!.callback();
  await pump(f.state);
  assert.match(f.app.status().error ?? "", /Could not open .*init\.js/);
  f.state.keys.find((k) => k.key === "b")!.callback();
  await pump(f.state);
  assert.equal(f.app.status().error, "availability exploded");
  assert.ok(f.state.notifications.includes("availability exploded"));
  f.app.stop();
});

test("invalid keymaps fail startup before anything is installed", async () => {
  const cases: [Options, RegExp][] = [
    [{keymap: {global: {"cmd-x": "nope"}}}, /Unknown command for cmd-x: nope/],
    [{keymap: {leader: {"w f c": "console"}}}, /W F is both a command and a prefix of w f c/],
    [
      {keymap: {leader: {"w f": "console", "w f x": "console"}}},
      /W F is both a command and a prefix of w f x/,
    ],
    [{keymap: {leader: {c: false, "c o": "console"}}}, /c o is under the disabled sequence C/],
    [
      {keymap: {global: {"cmd-option-1": "select-2", "command-alt-1": "select-3"}}},
      /command-alt-1 conflicts with cmd-option-1/,
    ],
    [{keymap: {leader: {"w f": "window-fill", "W F": "window-center"}}}, /repeats w f/],
    [{keymap: {global: {"option-space": "console"}}}, /conflicts with leader/],
    [{keymap: {global: {"cmd-x": 1 as never}}}, /must name a command or be false/],
    [{keymap: {leader: {x: {menu: ""}}}}, /must name a command, a \{menu\}, or be false/],
    [
      {keymap: {leader: {x: {menu: "M", extra: 1} as never}}},
      /Unknown keymap.leader x option: extra/,
    ],
    [{commands: {"select-1": {label: "x", action: () => {}}}}, /reserved/],
    [{commands: {"quick-app:x": {label: "x", action: () => {}}}}, /reserved/],
    [{commands: {bad: {label: "x"} as never}}, /needs an action function/],
    [{commands: {"a b": {label: "x", action: () => {}}}}, /Invalid command identity/],
    [{leader: "space" as never}, /Invalid shortcut: space/],
    [{keymap: {leader: {"w fn-f": "console"}}}, /Fn cannot be part of a sequence: w fn-f/],
    [{hud: {delay: -1}}, /hud.delay/],
    [{hud: {timeout: 0}}, /hud.timeout/],
    [{hud: {later: 1} as never}, /Unknown hud option: later/],
    [{spaces: false, keymap: {leader: {"s n": "desktop-create"}}}, /Unknown command for s n/],
    [
      {presets: [], keymap: {global: {"cmd-option-p": "presets"}}},
      /Unknown command for cmd-option-p/,
    ],
  ];
  for (const [options, message] of cases) {
    const {hs, state} = fakeHS();
    const api = createAPI(hs as HS, {providers: "/share/atelier/atelier-providers"});
    const app = createDefaults(hs, api, {expectedBuild: "133.1", version: "test"});
    await assert.rejects(app.start({...base, ...options}), message, JSON.stringify(options));
    assert.equal(app.status().state, "Stopped");
    assert.equal(state.keys.length, 0, JSON.stringify(options));
    assert.equal(state.taps.length, 0, JSON.stringify(options));
    assert.equal(state.tasks.length, 0, JSON.stringify(options));
  }
});

test("a failed leader tap or Fn binding releases everything, and leader: false binds nothing", async () => {
  const {hs, state} = fakeHS();
  const api = createAPI(hs, {providers: "/share/atelier/atelier-providers"});
  const app = createDefaults(hs, api, {expectedBuild: "133.1", version: "test"});
  state.tapsFail = true;
  await assert.rejects(app.start(base), /leader event tap/);
  assert.ok(state.keys.every((k) => k.destroyed));
  assert.ok(state.taps.every((t) => t.removed && !t.running));
  assert.equal(state.tasks[0]!.isRunning, false);
  // A tap that stops working later is reported when the leader is pressed.
  state.tapsFail = false;
  await app.start(base);
  state.tapsFail = true;
  state.keys.find((k) => k.key === "space")!.callback();
  assert.equal(app.status().leader?.active, false);
  assert.match(app.status().error ?? "", /leader event tap/);
  app.stop();
  const overlay = fakeHS();
  overlay.state.tapsFail = true;
  const withOverlay = createDefaults(
    overlay.hs,
    createAPI(overlay.hs, {providers: "/share/atelier/atelier-providers"}),
    {expectedBuild: "133.1", version: "test"},
  );
  await assert.rejects(withOverlay.start({quickApps: [], leader: false}), /overlay modifiers/);
  assert.ok(overlay.state.keys.every((k) => k.destroyed));
  const second = fakeHS();
  second.state.failBinding = "f";
  const other = createDefaults(
    second.hs,
    createAPI(second.hs, {providers: "/share/atelier/atelier-providers"}),
    {expectedBuild: "133.1", version: "test"},
  );
  await assert.rejects(
    other.start({...base, keymap: {global: {"fn-ctrl-f": "window-fill"}}}),
    /Shortcut unavailable: fn⌃F/,
  );
  assert.ok(second.state.keys.every((k) => k.destroyed));
  assert.ok(second.state.taps.every((t) => t.removed));
  const third = fakeHS();
  const bare = createDefaults(
    third.hs,
    createAPI(third.hs, {providers: "/share/atelier/atelier-providers"}),
    {expectedBuild: "133.1", version: "test"},
  );
  await bare.start({...base, leader: false});
  assert.equal(third.state.taps.length, 0);
  assert.ok(!third.state.keys.some((k) => k.key === "space"));
  assert.equal(bare.status().leader, null);
  bare.stop();
});

test("a leader at a shipped chord replaces that chord", async () => {
  const f = await leaderSession({leader: "cmd-option-1"});
  const chord = (k: {key: string; mods: string[]}) => k.key === "1" && k.mods.join() === "alt,cmd";
  assert.equal(f.state.keys.filter(chord).length, 1);
  f.state.keys.find(chord)!.callback();
  await pump(f.state);
  assert.deepEqual(f.app.status().leader, {shortcut: "⌥⌘1", active: true, path: []});
  assert.equal(
    f.app.status().metrics.some((m) => m.name === "select"),
    false,
  );
  f.app.stop();
});

test("Quick Apps and presets are leader commands only where the user maps them", async () => {
  const f = await leaderSession({
    quickApps: [{app: "Calculator", shortcut: "cmd-shift-c"}],
    presets: [{name: "Dev", apps: ["Ghostty"]}],
    keymap: {leader: {"a c": "quick-app:Calculator", "s p d": "preset:Dev"}},
  });
  await f.enter();
  assert.ok(f.texts().includes("Quick Apps"));
  await f.press("a");
  assert.deepEqual(
    f.texts().filter((t) => /Calculator|⇧⌘C/.test(t)),
    ["Calculator", "⇧⌘C"],
  );
  await f.press("delete");
  await f.press("s");
  await f.press("p");
  assert.equal(f.title(), "SPACES › DESKTOP PRESETS");
  assert.ok(f.texts().includes("Dev"));
  f.app.stop();
});

test("the tap is off while a command runs, so the keystrokes a Desktop command posts get through", async () => {
  const f = await leaderSession();
  // Records whether the tap was running when each providers request went out.
  const task = f.state.tasks[0]!,
    send = task.sendInput.bind(task),
    sent: [string, boolean][] = [];
  task.sendInput = (line) => {
    sent.push([(JSON.parse(line) as {command: string}).command, f.tap().running]);
    send(line);
  };
  await f.enter();
  await f.press("s");
  assert.equal(f.title(), "SPACES");
  await f.press("n");
  assert.deepEqual(
    sent.filter(([command]) => command === "spaces.create"),
    [["spaces.create", false]],
  );
  assert.equal(f.app.status().leader?.active, false);
  // A command that keeps the menu open turns the tap back on for the next key.
  let settle: (error?: Error) => void = () => {};
  const g = await leaderSession({
    commands: {
      slow: {
        label: "Slow",
        action: () =>
          new Promise<void>((resolve, reject) => {
            settle = (error) => (error ? reject(error) : resolve());
          }),
      },
    },
    keymap: {leader: {x: "slow"}},
  });
  await g.enter();
  await g.press("x");
  assert.equal(g.tap().running, false);
  assert.equal(g.app.status().leader?.active, true);
  // The HUD is gone while the command runs, so a Desktop switch cannot carry it along.
  assert.ok(g.canvas()!.destroyed);
  const canvases = g.state.canvases.length;
  settle(new Error("Slow failed"));
  await pump(g.state);
  assert.equal(g.tap().running, true);
  assert.equal(g.state.canvases.length, canvases + 1);
  assert.ok(g.canvas()!.showing);
  assert.equal(g.footer(), "Slow failed");
  assert.equal(await g.press("x"), false);
  settle();
  await pump(g.state);
  assert.equal(g.app.status().leader?.active, false);
  assert.equal(g.tap().running, false);
  // If the tap cannot come back, leader mode ends rather than letting keys through unnoticed.
  await g.enter();
  await g.press("x");
  g.state.tapsFail = true;
  settle(new Error("Slow failed again"));
  await pump(g.state);
  assert.equal(g.app.status().leader?.active, false);
  g.app.stop();
  f.app.stop();
});

test("digit keys are named although HS2's key map loses them to the codes they spell", async () => {
  // On HS2, `map["1"]` is the S key's name, so the map holds no name for key code 18.
  assert.equal(keycodeMap["1"], "s");
  assert.equal(keycodeMap["18"], undefined);
  const f = await leaderSession();
  await f.enter();
  await f.press("s");
  assert.equal(await f.press("2"), false);
  assert.ok(f.state.requests.some((r) => r.command === "spaces.switch" && r.number === 2));
  assert.equal(f.app.status().leader?.active, false);
  await f.enter();
  await f.press("s");
  await f.press("0");
  assert.ok(f.state.requests.some((r) => r.command === "spaces.switch" && r.number === 10));
  f.app.stop();
});

test("the Spaces menu lists the Desktops that exist, without fullscreen Spaces", async () => {
  const f = await leaderSession();
  const desktops = () => f.texts().filter((t) => /^Desktop \d+$/.test(t));
  await f.enter();
  await f.press("s");
  assert.deepEqual(desktops(), ["Desktop 1"]);
  assert.ok(f.texts().includes("Create Desktop"));
  await f.press("escape");
  // The next census sees two more Spaces, one of them a fullscreen app.
  f.state.snapshot.displays[0]!.spaces.push(
    {id: "2", fullscreen: false},
    {id: "3", fullscreen: true},
  );
  f.state.timers.find((t) => t.repeats && t.seconds === 2)!.callback();
  await pump(f.state);
  await f.enter();
  await f.press("s");
  assert.deepEqual(desktops(), ["Desktop 1", "Desktop 2"]);
  f.app.stop();
});
