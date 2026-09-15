// The Groups state file: where it lives, a tolerant read, and a debounced,
// deduplicated write. This is the only module that touches `hs.fs`. The file
// is human readable and safe to delete; every identity in it is checked
// against the live snapshot before use, so a stale file only loses members.
import type {HS} from "../api/hs.ts";
import type {Frame} from "../api/spaces.ts";

export interface SavedMember {
  pid: number;
  id: number;
  app: string;
  bundleID: string;
  filledFrame?: Frame;
}

export interface SavedGroup {
  display: string;
  space: string;
  members: SavedMember[];
}

export const stateVersion = 1;
export const debounceSeconds = 1;

export function statePath(hs: HS): string {
  return hs.fs.homeDirectory() + "/Library/Application Support/Atelier/groups.json";
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);
const isFrame = (value: unknown): value is Frame =>
  isRecord(value) && (["x", "y", "w", "h"] as const).every((k) => Number.isFinite(value[k]));

function member(value: unknown): SavedMember | null {
  if (
    !isRecord(value) ||
    !Number.isInteger(value.pid) ||
    !Number.isInteger(value.id) ||
    typeof value.app !== "string" ||
    typeof value.bundleID !== "string"
  )
    return null;
  const saved: SavedMember = {
    pid: value.pid as number,
    id: value.id as number,
    app: value.app,
    bundleID: value.bundleID,
  };
  if (isFrame(value.filledFrame)) saved.filledFrame = value.filledFrame;
  return saved;
}

/** The Groups in a file's text, or null when the text is not a Groups file. */
export function parse(text: string): SavedGroup[] | null {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch (_) {
    return null;
  }
  if (!isRecord(value) || value.version !== stateVersion || !Array.isArray(value.groups))
    return null;
  const groups: SavedGroup[] = [];
  for (const entry of value.groups) {
    if (
      !isRecord(entry) ||
      typeof entry.display !== "string" ||
      typeof entry.space !== "string" ||
      !Array.isArray(entry.members)
    )
      return null;
    const members = entry.members.map(member);
    if (members.some((m) => m === null)) return null;
    groups.push({display: entry.display, space: entry.space, members: members as SavedMember[]});
  }
  return groups;
}

export type ReadResult =
  | {status: "missing" | "unreadable" | "malformed"}
  | {status: "ok"; groups: SavedGroup[]};

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
    const groups = parse(text);
    if (!groups) return {status: "malformed"};
    this.written = this.serialize(groups);
    return {status: "ok", groups};
  }

  /** Schedules a write unless the file already holds these Groups. */
  save(groups: SavedGroup[]): void {
    const text = this.serialize(groups);
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

  private serialize(groups: SavedGroup[]): string {
    return JSON.stringify({version: stateVersion, groups}, null, 2) + "\n";
  }
}
