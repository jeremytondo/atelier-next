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

export interface WindowInfo {
  id: number;
  pid: number;
  space: string;
  frame: Frame;
  title: string;
  app: string;
  bundleID: string;
}

/** Topology, focus, and the on-screen window inventory. */
export interface Snapshot {
  trusted: boolean;
  focused: number;
  targetDisplay: string;
  missionControl: boolean;
  displays: DisplayInfo[];
  windows: WindowInfo[];
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
  /** Space membership of one window; empty for unknown or hidden windows. */
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
