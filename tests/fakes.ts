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

export interface FakeState {
  tasks: FakeTask[];
  timers: FakeTimer[];
  keys: FakeKey[];
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

export function fakeHS(): {hs: HS; state: FakeState} {
  const snapshot: Snapshot = {
    trusted: true,
    focused: 0,
    targetDisplay: "Main",
    missionControl: false,
    displays: [{id: "Main", current: "1", spaces: [{id: "1", fullscreen: false}]}],
    windows: [],
  };
  const state: FakeState = {
    tasks: [],
    timers: [],
    keys: [],
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
    application: {fromPID: (): unknown => null},
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

export interface FakeApp {
  /** Window IDs whose native Fill was pressed, in order. */
  fills: number[];
  /** Whether the Fill menu item exists; false makes every Fill fail. */
  fillAvailable: boolean;
  application: Record<string, unknown>;
}

/** A menu bar whose only item is native Fill, recording each press on `fake`. */
function fillMenu(hs: HS, state: FakeState, fake: FakeApp) {
  hs.ax.applicationElement = (() => ({
    attributeValue: () => ({
      attributeValue: (name: string) =>
        name === "AXIdentifier" && fake.fillAvailable ? "_zoomFill:" : null,
      children: () => [],
      isEnabled: true,
      performAction: () => {
        fake.fills.push(state.snapshot.focused);
        return true;
      },
    }),
  })) as unknown as typeof hs.ax.applicationElement;
}

/** Windows of process 42 on Desktop 1 that focus and Fill through the fakes. */
export function fakeApp(hs: HS, state: FakeState, ids: number[]): FakeApp {
  const fake: FakeApp = {
    fills: [],
    fillAvailable: true,
    application: {bundleID: "fixture", axElement: () => ({setAttributeValueValue: () => true})},
  };
  const windows = ids.map((id) => ({
    id,
    pid: 42,
    application: fake.application,
    frame: {x: 0, y: 0, w: 400, h: 300},
    axElement: () => ({
      setAttributeValueValue: () => true,
      performAction: () => {
        state.snapshot.focused = id;
        return true;
      },
    }),
  }));
  fake.application.allWindows = windows;
  hs.application.fromPID = (() => fake.application) as unknown as typeof hs.application.fromPID;
  hs.window.focusedWindow = (() =>
    windows.find(
      (w) => w.id === state.snapshot.focused,
    )) as unknown as typeof hs.window.focusedWindow;
  fillMenu(hs, state, fake);
  state.snapshot.focused = ids[0] ?? 0;
  state.snapshot.windows = ids.map((id) => ({
    id,
    pid: 42,
    space: "1",
    frame: {x: 0, y: 0, w: 400, h: 300},
    title: "",
    app: "fixture",
    bundleID: "fixture",
  }));
  return fake;
}

/** Bridges `hs.application` and `hs.window` to a fake Mac's processes so the
 *  windows it lists focus and Fill through the fakes. The Spaces inventory
 *  stays the test's to fill. */
export function fakeMac(hs: HS, state: FakeState, mac: FakeWorkspace): FakeApp {
  const fake: FakeApp = {fills: [], fillAvailable: true, application: {}};
  const element = () => ({setAttributeValueValue: () => true});
  const window = (pid: number, id: number) => ({
    id,
    pid,
    application: {bundleID: mac.apps.get(pid)?.bundleID, axElement: element},
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
  fillMenu(hs, state, fake);
  return fake;
}
