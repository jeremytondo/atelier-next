// Small fakes of the HS2 boundaries Atelier uses and of the providers pipe;
// no macOS state is touched. `state` exposes what the fakes recorded.
import type {HS} from "../api/hs.ts";
import {protocolVersion} from "../api/pipe.ts";
import type {Snapshot} from "../api/spaces.ts";
import type {FakeWorkspace} from "./fake-workspace.ts";

export interface FakeTask {
  path: string;
  args: string[];
  isRunning: boolean;
  ended: (code: number, reason: string) => void;
  output: (channel: string, text: string) => void;
  start(): FakeTask;
  terminate(): void;
  sendInput(line: string): void;
}

export interface FakeTimer {
  seconds: number;
  repeats: boolean;
  callback: () => void;
  stopped: boolean;
  stop(): void;
}

export interface FakeKey {
  mods: string[];
  key: string;
  callback: () => void;
  /** The key-repeat callback, null when holding the key does nothing more. */
  repeat: (() => void) | null;
  enabled: boolean;
  destroyed: boolean;
  enable(): boolean;
  disable(): void;
  destroy(): void;
}

export interface FakeEvent {
  type: number;
  keyCode: number;
  flags: string[];
}

export interface FakeTap {
  types: number[];
  callback: (event: FakeEvent) => boolean | undefined;
  listenOnly: boolean;
  running: boolean;
  removed: boolean;
  start(): FakeTap;
  stop(): FakeTap;
  isEnabled(): boolean;
}

/** An event-tap hotkey, the path Fn chords take. */
export interface FakeEventHotkey {
  mods: string[];
  key: string;
  callback: () => void;
  enabled: boolean;
  removed: boolean;
  enable(): boolean;
  disable(): void;
}

export interface FakeElement {
  text?: string;
  textColor?: {alpha: number};
  roundedRectRadii?: {xRadius: number};
  frame?: {x: number; y: number; w: number; h: number};
}

export interface FakeCanvas {
  frame: unknown;
  showing: boolean;
  destroyed: boolean;
  shows: number;
  elements: FakeElement[];
  level(): FakeCanvas;
  behaviorList(): FakeCanvas;
  clickActivating(): FakeCanvas;
  ignoreMouseEvents(): FakeCanvas;
  setFrame(value: unknown): FakeCanvas;
  replaceElements(value: FakeElement[]): FakeCanvas;
  show(): FakeCanvas;
  hide(): void;
  destroy(): void;
}

export interface FakeScreen {
  uuid: string;
  frame: {x: number; y: number; w: number; h: number};
  fullFrame: {x: number; y: number; w: number; h: number};
}

export interface FakeState {
  tasks: FakeTask[];
  timers: FakeTimer[];
  keys: FakeKey[];
  taps: FakeTap[];
  /** Whether starting a tap fails, as HS2 does without Accessibility. */
  tapsFail: boolean;
  eventHotkeys: FakeEventHotkey[];
  canvases: FakeCanvas[];
  screens: FakeScreen[];
  /** The screen with keyboard focus; the first screen when null. */
  mainScreen: FakeScreen | null;
  watched: unknown[][];
  removedWatchers: unknown[][];
  snapshot: Snapshot;
  replies: boolean;
  trusted: boolean;
  failBinding: string | null;
  requests: Record<string, unknown>[];
  /** How many launches still exit at once with the lock-held status. */
  lockedLaunches: number;
  build: string;
  notifications: string[];
  hostTrusted?: boolean;
  dialogs: {
    message: string;
    detail: string;
    labels: string[];
    click: (index: number) => void;
    closed: boolean;
  }[];
  openedURLs: string[];
  openURLResult: boolean;
  consoleOpened: boolean;
  accessibilityRequests: number;
  notificationRequests: number;
  reloaded?: boolean;
  /** Path to contents, the fake disk. */
  files: Record<string, string>;
  writable: boolean;
  choosers: FakeChooser[];
  /** App references the fake providers cannot resolve. */
  missingApps: string[];
  /** App references that resolve to another reference's app, like a bundle ID. */
  aliases: Record<string, string>;
}

export interface FakeChooser {
  choices: {text: string; subText?: string}[];
  placeholder: string;
  query: string;
  isVisible: boolean;
  onSelect: ((item: {text: string} | null) => void) | null;
  setChoices(choices: {text: string; subText?: string}[]): FakeChooser;
  show(): FakeChooser;
  hide(): FakeChooser;
}

/** HS2's event type numbers, as `hs.eventtap.eventTypes` names them. */
export const eventTypes: Record<string, number> = {
  leftMouseDown: 1,
  rightMouseDown: 3,
  keyDown: 10,
  keyUp: 11,
  flagsChanged: 12,
  otherMouseDown: 25,
};

/** Key names and codes on a US layout, in one map the way HS2 builds
 *  `hs.keycodes.map`: named keys first, then each key code's character unless
 *  either string is taken, so a digit's name is lost to the code it spells. */
export const keycodeMap: Record<string, string | number> = {};
const keyCodes: Record<string, number> = {};
{
  const codes: Record<string, number> = {
    a: 0,
    s: 1,
    d: 2,
    f: 3,
    h: 4,
    g: 5,
    z: 6,
    x: 7,
    c: 8,
    v: 9,
    b: 11,
    q: 12,
    w: 13,
    e: 14,
    r: 15,
    y: 16,
    t: 17,
    "1": 18,
    "2": 19,
    "3": 20,
    "4": 21,
    "6": 22,
    "5": 23,
    "=": 24,
    "9": 25,
    "7": 26,
    "-": 27,
    "8": 28,
    "0": 29,
    "]": 30,
    o: 31,
    u: 32,
    "[": 33,
    i: 34,
    p: 35,
    l: 37,
    j: 38,
    "'": 39,
    k: 40,
    ";": 41,
    "\\": 42,
    ",": 43,
    "/": 44,
    n: 45,
    m: 46,
    ".": 47,
    "`": 50,
    return: 36,
    tab: 48,
    space: 49,
    delete: 51,
    escape: 53,
    left: 123,
    right: 124,
    down: 125,
    up: 126,
  };
  Object.assign(keyCodes, codes);
  const named = ["return", "tab", "space", "delete", "escape", "left", "right", "down", "up"];
  for (const name of named) {
    keycodeMap[name] = codes[name]!;
    keycodeMap[String(codes[name])] = name;
  }
  const characters = Object.entries(codes)
    .filter(([name]) => !named.includes(name))
    .sort((a, b) => a[1] - b[1]);
  for (const [name, code] of characters) {
    if (keycodeMap[name] !== undefined || keycodeMap[String(code)] !== undefined) continue;
    keycodeMap[name] = code;
    keycodeMap[String(code)] = name;
  }
}

/** A key event for a fake tap: the key's code and the modifiers HS2 would report. */
export function keyEvent(key: string, flags: string[] = [], type = eventTypes.keyDown!): FakeEvent {
  const code = keyCodes[key];
  if (typeof code !== "number") throw new Error("No key code for " + key);
  return {type, keyCode: code, flags};
}

export function fakeHS(): {hs: HS; state: FakeState} {
  const snapshot: Snapshot = {
    trusted: true,
    focused: 0,
    focusedSpace: "1",
    targetDisplay: "Main",
    missionControl: false,
    displays: [{id: "Main", current: "1", spaces: [{id: "1", fullscreen: false}]}],
    windows: [],
    complete: true,
  };
  const state: FakeState = {
    tasks: [],
    timers: [],
    keys: [],
    taps: [],
    tapsFail: false,
    eventHotkeys: [],
    canvases: [],
    screens: [
      {uuid: "D", frame: {x: 0, y: 0, w: 1200, h: 800}, fullFrame: {x: 0, y: 0, w: 1200, h: 800}},
    ],
    mainScreen: null,
    watched: [],
    removedWatchers: [],
    snapshot,
    replies: true,
    trusted: true,
    failBinding: null,
    requests: [],
    lockedLaunches: 0,
    build: "133.1",
    notifications: [],
    dialogs: [],
    openedURLs: [],
    openURLResult: true,
    consoleOpened: false,
    accessibilityRequests: 0,
    notificationRequests: 0,
    files: {},
    writable: true,
    choosers: [],
    missingApps: [],
    aliases: {},
  };
  const timer = (seconds: number, repeats: boolean, callback: () => void): FakeTimer => {
    const value: FakeTimer = {
      seconds,
      repeats,
      callback,
      stopped: false,
      stop() {
        this.stopped = true;
      },
    };
    state.timers.push(value);
    return value;
  };
  const hs = {
    openConsole: () => {
      state.consoleOpened = true;
    },
    urlevent: {
      openURL: (url: string) => {
        state.openedURLs.push(url);
        return state.openURLResult;
      },
    },
    ui: {
      dialog: (message: string) => {
        const dialog = {
          message,
          detail: "",
          labels: [] as string[],
          click: (_: number) => {},
          closed: false,
          informativeText(value: string) {
            this.detail = value;
            return this;
          },
          buttons(value: string[]) {
            this.labels = value;
            return this;
          },
          onButton(value: (index: number) => void) {
            this.click = value;
            return this;
          },
          show() {
            return this;
          },
          close() {
            this.closed = true;
          },
        };
        state.dialogs.push(dialog);
        return dialog;
      },
    },
    reload: () => {
      state.reloaded = true;
    },
    fs: {
      homeDirectory: () => "/Users/fake",
      isFile: (path: string) => Object.hasOwn(state.files, path),
      read: (path: string) => state.files[path] ?? null,
      mkdir: () => state.writable,
      write: (path: string, content: string) => {
        if (!state.writable) return false;
        state.files[path] = content;
        return true;
      },
    },
    appinfo: {
      get build() {
        return state.build;
      },
      bundleIdentifier: "net.tenshu.Hammerspoon-2",
      configPath: "/Users/fake/.config/atelier/init.js",
    },
    eventtap: {
      eventTypes,
      emit: true,
      consume: false,
      addWatcher(types: number[], callback: FakeTap["callback"], listenOnly: boolean) {
        const tap: FakeTap = {
          types,
          callback,
          listenOnly,
          running: false,
          removed: false,
          start() {
            this.running = !state.tapsFail;
            return this;
          },
          stop() {
            this.running = false;
            return this;
          },
          isEnabled() {
            return this.running;
          },
        };
        state.taps.push(tap);
        return tap;
      },
      removeWatcher(tap: FakeTap) {
        tap.running = false;
        tap.removed = true;
      },
      bindHotkey(mods: string[], key: string, callback: () => void) {
        if (key === state.failBinding) return null;
        const hotkey: FakeEventHotkey = {
          mods,
          key,
          callback,
          enabled: true,
          removed: false,
          enable() {
            this.enabled = true;
            return true;
          },
          disable() {
            this.enabled = false;
          },
        };
        state.eventHotkeys.push(hotkey);
        return hotkey;
      },
      removeHotkey(hotkey: FakeEventHotkey) {
        hotkey.enabled = false;
        hotkey.removed = true;
      },
    },
    keycodes: {map: keycodeMap},
    canvas: {
      create: (frame: unknown) => {
        const canvas: FakeCanvas = {
          frame,
          showing: false,
          destroyed: false,
          shows: 0,
          elements: [],
          level() {
            return this;
          },
          behaviorList() {
            return this;
          },
          clickActivating() {
            return this;
          },
          ignoreMouseEvents() {
            return this;
          },
          setFrame(value) {
            this.frame = value;
            return this;
          },
          replaceElements(value) {
            this.elements = value;
            return this;
          },
          show() {
            if (this.destroyed) throw new Error("Canvas was destroyed");
            this.showing = true;
            this.shows++;
            return this;
          },
          hide() {
            this.showing = false;
          },
          destroy() {
            this.destroyed = true;
            this.showing = false;
          },
        };
        state.canvases.push(canvas);
        return canvas;
      },
    },
    screen: {
      primary: () => state.screens[0] ?? null,
      main: () => state.mainScreen ?? state.screens[0] ?? null,
      all: () => state.screens,
    },
    permissions: {
      checkAccessibility: () => state.hostTrusted ?? state.trusted,
      requestAccessibility: () => {
        state.accessibilityRequests++;
      },
      requestNotifications: () => {
        state.notificationRequests++;
        return Promise.resolve(true);
      },
    },
    timer: {
      doAfter: (seconds: number, callback: () => void) => timer(seconds, false, callback),
      doEvery: (seconds: number, callback: () => void) => timer(seconds, true, callback),
    },
    task: {
      create(
        path: string,
        args: string[],
        ended: (code: number, reason: string) => void,
        _: unknown,
        output: (channel: string, text: string) => void,
      ) {
        const task: FakeTask = {
          path,
          args,
          isRunning: false,
          output,
          ended,
          start() {
            this.isRunning = true;
            if (state.lockedLaunches > 0) {
              state.lockedLaunches--;
              queueMicrotask(() => {
                this.isRunning = false;
                ended(75, "exit");
              });
            }
            return this;
          },
          terminate() {
            this.isRunning = false;
          },
          sendInput(line: string) {
            const request = JSON.parse(line) as Record<string, unknown> & {
              id: number;
              command: string;
            };
            state.requests.push(request);
            if (!state.replies) return;
            let result: unknown;
            const copy = () => JSON.parse(JSON.stringify(snapshot)) as Snapshot;
            switch (request.command) {
              case "hello":
                result = {protocolVersion, trusted: state.trusted};
                break;
              case "application.resolve":
                if (state.missingApps.includes(String(request.app))) {
                  const error = "No application named " + request.app;
                  queueMicrotask(() =>
                    output("stdout", JSON.stringify({id: request.id, ok: false, error}) + "\n"),
                  );
                  return;
                }
                result = {
                  bundleID: "app." + (state.aliases[String(request.app)] ?? request.app),
                  name: request.app,
                  path: "/Applications/" + request.app + ".app",
                };
                break;
              case "application.launch":
                result = {pid: 20};
                break;
              case "spaces.membership":
                result = {spaces: ["1"], focused: snapshot.focused};
                break;
              case "spaces.pin":
                result = {assignment: "assigned"};
                break;
              default:
                result = copy();
            }
            queueMicrotask(() =>
              output("stdout", JSON.stringify({id: request.id, ok: true, result}) + "\n"),
            );
          },
        };
        state.tasks.push(task);
        return task;
      },
    },
    hotkey: {
      assignable: () => true,
      getHotkeys: () => state.keys.filter((k) => k.enabled),
      create(
        mods: string[],
        name: string,
        callback: () => void,
        _: unknown,
        repeat: (() => void) | null,
      ) {
        const key: FakeKey = {
          mods,
          key: name,
          callback,
          repeat,
          enabled: false,
          destroyed: false,
          enable() {
            if (name === state.failBinding) return false;
            this.enabled = true;
            return true;
          },
          disable() {
            this.enabled = false;
          },
          destroy() {
            this.disable();
            this.destroyed = true;
          },
        };
        state.keys.push(key);
        return key;
      },
    },
    application: {fromPID: (): unknown => null, frontmost: (): unknown => null},
    window: {focusedWindow: (): unknown => null},
    ax: {
      applicationElement: (): unknown => null,
      addWatcher: (...args: unknown[]) => state.watched.push(args),
      removeWatcher: (...args: unknown[]) => state.removedWatchers.push(args),
    },
    notify: {
      show: (_: string, body: string) => {
        state.notifications.push(body);
      },
    },
    chooser: {
      create: () => {
        const chooser: FakeChooser = {
          choices: [],
          placeholder: "Search...",
          query: "",
          isVisible: false,
          onSelect: null,
          setChoices(choices) {
            this.choices = choices;
            return this;
          },
          show() {
            this.isVisible = true;
            return this;
          },
          hide() {
            this.isVisible = false;
            return this;
          },
        };
        state.choosers.push(chooser);
        return chooser;
      },
    },
  };
  return {hs: hs as unknown as HS, state};
}

export interface FakeWindow {
  id: number;
  pid: number;
  isMinimized: boolean;
  /** How often `unminimize` was called. */
  unminimized: number;
  application: FakeApplication;
  frame: {x: number; y: number; w: number; h: number};
  unminimize(): boolean;
  axElement(): Record<string, unknown>;
}

export interface FakeApplication {
  bundleID: string;
  isHidden: boolean;
  /** How often `unhide` was called. */
  unhidden: number;
  allWindows: FakeWindow[];
  unhide(): void;
  axElement(): Record<string, unknown>;
}

export interface FakeApp {
  application: FakeApplication;
  windows: FakeWindow[];
  /** Whether raising a window moves focus; false makes every focus attempt fail. */
  focusWorks: boolean;
  /** Window IDs whose focus attempt should land on a dialog of the app instead. */
  dialogs: Set<number>;
}

/** A census entry for `fakeApp` and `fakeMac` windows: ordinary, on Desktop 1, visible. */
export function inventoried(
  id: number,
  pid: number,
  extra: Partial<Snapshot["windows"][number]> = {},
): Snapshot["windows"][number] {
  return {
    id,
    pid,
    launched: 1,
    app: "fixture",
    bundleID: "fixture",
    title: "",
    spaces: ["1"],
    onScreen: true,
    ordinary: true,
    ...extra,
  };
}

const element = (ordinary = true) => ({
  setAttributeValueValue: () => true,
  role: "AXWindow",
  isAttributeSettable: () => ordinary,
});

/** Windows of process 42 on Desktop 1 that reveal and focus through the fakes. */
export function fakeApp(hs: HS, state: FakeState, ids: number[]): FakeApp {
  const application: FakeApplication = {
    bundleID: "fixture",
    isHidden: false,
    unhidden: 0,
    allWindows: [],
    unhide() {
      this.isHidden = false;
      this.unhidden++;
    },
    axElement: () => element(),
  };
  const fake: FakeApp = {application, windows: [], focusWorks: true, dialogs: new Set()};
  fake.windows = ids.map((id) => ({
    id,
    pid: 42,
    isMinimized: false,
    unminimized: 0,
    application,
    frame: {x: 0, y: 0, w: 400, h: 300},
    unminimize() {
      this.isMinimized = false;
      this.unminimized++;
      return true;
    },
    axElement: () => ({
      ...element(),
      performAction: () => {
        if (fake.focusWorks) state.snapshot.focused = fake.dialogs.has(id) ? -id : id;
        return true;
      },
    }),
  }));
  application.allWindows = fake.windows;
  hs.application.fromPID = (() => application) as unknown as typeof hs.application.fromPID;
  hs.window.focusedWindow = (() => {
    const focused = state.snapshot.focused;
    // A negative ID stands for a dialog of the app that macOS keeps in front.
    if (focused < 0) return {id: focused, pid: 42, application, axElement: () => element(false)};
    return fake.windows.find((w) => w.id === focused);
  }) as unknown as typeof hs.window.focusedWindow;
  hs.ax.applicationElement = (() => ({})) as unknown as typeof hs.ax.applicationElement;
  state.snapshot.focused = ids[0] ?? 0;
  state.snapshot.windows = ids.map((id) => inventoried(id, 42));
  return fake;
}

/** Bridges `hs.application` and `hs.window` to a fake Mac's processes so the
 *  windows it lists reveal and focus through the fakes. The census stays the
 *  test's to fill. */
export function fakeMac(hs: HS, state: FakeState, mac: FakeWorkspace): void {
  const window = (pid: number, id: number) => ({
    id,
    pid,
    application: {
      bundleID: mac.apps.get(pid)?.bundleID,
      get isHidden() {
        return mac.isHidden(pid);
      },
      unhide: () => mac.unhide(pid),
      axElement: element,
    },
    get isMinimized() {
      return mac.isMinimized(id);
    },
    unminimize: () => mac.unminimize(id),
    frame: mac.frame(id) ?? {x: 0, y: 0, w: 400, h: 300},
    axElement: () => ({
      ...element(),
      performAction: () => {
        state.snapshot.focused = id;
        mac.focus(pid, id);
        return true;
      },
    }),
  });
  hs.application.fromPID = ((pid: number) => {
    const app = mac.apps.get(pid);
    return (
      app && {
        bundleID: app.bundleID,
        get isHidden() {
          return app.hidden;
        },
        unhide: () => mac.unhide(pid),
        allWindows: app.windows.map((id) => window(pid, id)),
        axElement: element,
      }
    );
  }) as unknown as typeof hs.application.fromPID;
  hs.window.focusedWindow = (() => {
    for (const [pid, app] of mac.apps)
      if (app.windows.includes(state.snapshot.focused)) return window(pid, state.snapshot.focused);
    return null;
  }) as unknown as typeof hs.window.focusedWindow;
  hs.ax.applicationElement = (() => ({})) as unknown as typeof hs.ax.applicationElement;
}

export interface FakeMenuItem {
  title?: string;
  identifier?: string;
  enabled?: boolean;
  char?: string;
  mods?: number;
  virtualKey?: number;
  children?: FakeMenuItem[];
}

/** An Accessibility element with the attributes the window API reads. */
export function axElement(
  item: FakeMenuItem,
  pressed: string[],
  pressResult = true,
): Record<string, unknown> {
  const attributes: Record<string, unknown> = {
    AXIdentifier: item.identifier ?? "",
    AXMenuItemCmdChar: item.char ?? "",
    AXMenuItemCmdModifiers: item.mods ?? 0,
    AXMenuItemCmdVirtualKey: item.virtualKey ?? null,
  };
  return {
    title: item.title ?? "",
    isEnabled: item.enabled ?? false,
    attributeValue: (name: string) => attributes[name] ?? null,
    children: () => (item.children ?? []).map((child) => axElement(child, pressed, pressResult)),
    performAction: (action: string) => {
      pressed.push(item.identifier + ":" + action);
      return pressResult;
    },
  };
}

export interface FakeMenuBar {
  /** Identifiers pressed, as `identifier:action`. */
  pressed: string[];
  pressResult: boolean;
  focused: {id: number; pid: number} | null;
  app: {title: string; pid: number} | null;
  menus: FakeMenuItem[];
}

/** Makes the frontmost app's menu bar answer `hs.ax` with the given top-level menus. */
export function fakeMenuBar(hs: HS, menus: FakeMenuItem[]): FakeMenuBar {
  const bar: FakeMenuBar = {
    pressed: [],
    pressResult: true,
    focused: {id: 7, pid: 42},
    app: {title: "Fixture", pid: 42},
    menus,
  };
  hs.application.frontmost = (() => bar.app) as unknown as typeof hs.application.frontmost;
  hs.window.focusedWindow = (() => bar.focused) as unknown as typeof hs.window.focusedWindow;
  hs.ax.applicationElement = (() => ({
    attributeValue: (name: string) =>
      name === "AXMenuBar"
        ? {children: () => bar.menus.map((menu) => axElement(menu, bar.pressed, bar.pressResult))}
        : null,
  })) as unknown as typeof hs.ax.applicationElement;
  return bar;
}

/** Apple's Window menu as macOS 27 exposes it, with every native action `enabled`. */
export function windowMenu(enabled = true, extra: FakeMenuItem[] = []): FakeMenuItem {
  const item = (title: string, identifier: string, shortcut: Partial<FakeMenuItem> = {}) => ({
    title,
    identifier,
    enabled,
    ...shortcut,
  });
  return {
    title: "Window",
    children: [
      {
        children: [
          item("Minimize", "_NS:371", {char: "M", mods: 0}),
          item("Fill", "_zoomFill:", {char: "F", mods: 28}),
          item("Center", "_zoomCenter:", {char: "C", mods: 28}),
          {title: ""},
          {
            title: "Move & Resize",
            children: [
              {
                children: [
                  {title: "Halves"},
                  item("Left", "_zoomLeft:", {mods: 28, virtualKey: 123}),
                  item("Right", "_zoomRight:", {mods: 28, virtualKey: 124}),
                  item("Top", "_zoomTop:", {mods: 28, virtualKey: 126}),
                  item("Bottom", "_zoomBottom:", {mods: 28, virtualKey: 125}),
                  item("Top Left", "_zoomTopLeft:"),
                  item("Top Right", "_zoomTopRight:"),
                  item("Bottom Left", "_zoomBottomLeft:"),
                  item("Bottom Right", "_zoomBottomRight:"),
                  item("Left & Right", "_zoomLeftAndRight:", {mods: 29, virtualKey: 123}),
                  item("Left & Quarters", "_zoomLeftThreeUp:", {mods: 31, virtualKey: 123}),
                  item("Right & Left", "_zoomRightAndLeft:", {mods: 29, virtualKey: 124}),
                  item("Right & Quarters", "_zoomRightThreeUp:", {mods: 31, virtualKey: 124}),
                  item("Top & Bottom", "_zoomTopAndBottom:", {mods: 29, virtualKey: 126}),
                  item("Top & Quarters", "_zoomTopThreeUp:", {mods: 31, virtualKey: 126}),
                  item("Bottom & Top", "_zoomBottomAndTop:", {mods: 29, virtualKey: 125}),
                  item("Bottom & Quarters", "_zoomBottomThreeUp:", {mods: 31, virtualKey: 125}),
                  item("Quarters", "_zoomQuarters:"),
                  item("Return to Previous Size", "_zoomUntile:", {char: "R", mods: 28}),
                ],
              },
            ],
          },
          ...extra,
        ],
      },
    ],
  };
}
