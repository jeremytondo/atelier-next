// Small fakes of the HS2 boundaries Atelier uses and of the providers pipe;
// no macOS state is touched. `state` exposes what the fakes recorded.
import type {HS} from "../api/hs.ts";
import {protocolVersion} from "../api/pipe.ts";
import type {Snapshot} from "../api/spaces.ts";

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
                result = {
                  bundleID: "app." + request.app,
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
      create(mods: string[], name: string, callback: () => void) {
        const key: FakeKey = {
          mods,
          key: name,
          callback,
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
  };
  return {hs: hs as unknown as HS, state};
}
