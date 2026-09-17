// `atelier.spaces` fills the missing `hs.spaces`. Every call is a request to
// the Spaces provider; the shapes here mirror PipeProtocol.swift.
export interface Frame {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface SpaceInfo {
  id: string;
  fullscreen: boolean;
}

export interface DisplayInfo {
  id: string;
  current: string;
  spaces: SpaceInfo[];
}

/** A window in the provider's census, on any Space, minimized or hidden; confirmed closures excluded. */
export interface WindowInfo {
  id: number;
  pid: number;
  /** The process launch time in seconds since 1970; with the PID, an identity a restart cannot recycle. */
  launched: number;
  app: string;
  bundleID: string;
  title: string;
  /** Desktop membership; empty when the window server reports none. */
  spaces: string[];
  onScreen: boolean;
  /** Whether Accessibility calls this an ordinary window; absent when it did not list the window. */
  ordinary?: boolean;
}

/** Topology, focus, and the window census. */
export interface Snapshot {
  trusted: boolean;
  focused: number;
  /** The Space that receives keyboard input; window commands act on its Desktop. */
  focusedSpace: string;
  targetDisplay: string;
  missionControl: boolean;
  displays: DisplayInfo[];
  windows: WindowInfo[];
  /** Whether `displays` and `windows` are complete; false is not evidence that anything closed. */
  complete: boolean;
  created?: string;
  migratedWindows?: {id: number; spaces: string[]}[];
}

export interface Membership {
  spaces: string[];
  focused: number;
}

/** The display and Desktop the caller last observed; the provider refuses if either moved. */
export interface Target {
  display?: string;
  current?: string;
}

export interface SpacesAPI {
  snapshot(): Promise<Snapshot>;
  /** Space membership of one window; empty for unknown windows. */
  membership(window: number): Promise<Membership>;
  switch(args: Target & {number: number}): Promise<Snapshot | {noop: true}>;
  create(args?: Target): Promise<Snapshot>;
  reorder(args: Target & {offset: -1 | 1}): Promise<Snapshot>;
  delete(args?: Target): Promise<Snapshot>;
  /** Puts a window's process on every listed Desktop; `app` is its bundle path. */
  pin(args: {pid: number; window: number; app: string; spaces: string[]}): Promise<{
    assignment: string;
  }>;
}

export type Request = (command: string, args?: object) => Promise<unknown>;

export function createSpaces(request: Request): SpacesAPI {
  const call = <Result>(name: string, args?: object) =>
    request("spaces." + name, args) as Promise<Result>;
  return {
    snapshot: () => call("snapshot"),
    membership: (window) => call("membership", {window}),
    switch: (args) => call("switch", args),
    create: (args = {}) => call("create", args),
    reorder: (args) => call("reorder", args),
    delete: (args = {}) => call("delete", args),
    pin: (args) => call("pin", args),
  };
}
