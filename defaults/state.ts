// The window lists' state file: where it lives, a tolerant read, and a
// debounced, deduplicated write. This is the only module that touches `hs.fs`.
// The file is human readable and safe to delete; every identity in it is
// checked against the live census before use, so a stale file only loses entries.
import type {HS} from "../api/hs.ts";

export interface SavedWindow {
  pid: number;
  id: number;
  /** The process launch time, positive; with the PID, an identity a restart cannot recycle. */
  launched: number;
  app: string;
  bundleID: string;
}

export interface SavedDesktop {
  display: string;
  space: string;
  windows: SavedWindow[];
}

export const stateVersion = 1;
export const debounceSeconds = 1;

export function statePath(hs: HS): string {
  return hs.fs.homeDirectory() + "/Library/Application Support/Atelier/windows.json";
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);

function window(value: unknown): SavedWindow | null {
  if (
    !isRecord(value) ||
    !Number.isInteger(value.pid) ||
    !Number.isInteger(value.id) ||
    !(Number.isFinite(value.launched) && (value.launched as number) > 0) ||
    typeof value.app !== "string" ||
    typeof value.bundleID !== "string"
  )
    return null;
  return {
    pid: value.pid as number,
    id: value.id as number,
    launched: value.launched as number,
    app: value.app,
    bundleID: value.bundleID,
  };
}

/** The lists in a file's text, or null when the text is not a window lists file. */
export function parse(text: string): SavedDesktop[] | null {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch (_) {
    return null;
  }
  if (!isRecord(value) || value.version !== stateVersion || !Array.isArray(value.desktops))
    return null;
  const desktops: SavedDesktop[] = [];
  for (const entry of value.desktops) {
    if (
      !isRecord(entry) ||
      typeof entry.display !== "string" ||
      typeof entry.space !== "string" ||
      !Array.isArray(entry.windows)
    )
      return null;
    const windows = entry.windows.map(window);
    if (windows.some((w) => w === null)) return null;
    desktops.push({display: entry.display, space: entry.space, windows: windows as SavedWindow[]});
  }
  return desktops;
}

export type ReadResult =
  | {status: "missing" | "unreadable" | "malformed"}
  | {status: "ok"; desktops: SavedDesktop[]};

export class StateFile {
  readonly path: string;
  private readonly hs: HS;
  private written: string | null = null;
  private pending: string | null = null;
  private timer: HSTimer | null = null;
  private failed = false;
  /** ISO time of the last successful write in this context. */
  savedAt: string | null = null;

  constructor(hs: HS, path = statePath(hs)) {
    this.hs = hs;
    this.path = path;
  }

  read(): ReadResult {
    const fs = this.hs.fs;
    // The file is the truth from here: an unchanged restore must not rewrite it,
    // and a missing or broken one must be written on the next save.
    this.written = null;
    if (!fs.isFile(this.path)) return {status: "missing"};
    const text = fs.read(this.path, 0, 0);
    if (text === null) return {status: "unreadable"};
    const desktops = parse(text);
    if (!desktops) return {status: "malformed"};
    this.written = this.serialize(desktops);
    return {status: "ok", desktops};
  }

  /** Schedules a write unless the file already holds these lists. */
  save(desktops: SavedDesktop[]): void {
    const text = this.serialize(desktops);
    if (text === this.written) {
      this.pending = null;
      return;
    }
    this.pending = text;
    if (!this.timer) this.timer = this.hs.timer.doAfter(debounceSeconds, () => this.flush());
  }

  /** Writes any scheduled change now. */
  flush(): void {
    this.timer?.stop();
    this.timer = null;
    const text = this.pending;
    this.pending = null;
    if (text === null || text === this.written) return;
    const fs = this.hs.fs,
      directory = this.path.slice(0, this.path.lastIndexOf("/"));
    if (fs.mkdir(directory) && fs.write(this.path, text)) {
      this.written = text;
      this.savedAt = new Date().toISOString();
      this.failed = false;
      return;
    }
    if (!this.failed) console.error("Atelier: Could not write " + this.path);
    this.failed = true;
  }

  private serialize(desktops: SavedDesktop[]): string {
    return JSON.stringify({version: stateVersion, desktops}, null, 2) + "\n";
  }
}
