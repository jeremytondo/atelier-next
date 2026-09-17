// Bounded JSON-lines requests to one owned atelier-providers process. A lost
// response has an unknown outcome: the pipe fails, the owner stops, and no
// mutation is ever replayed automatically.
import type {HS} from "./hs.ts";
import {Timers} from "./timers.ts";

export const protocolVersion = 4;
/// atelier-providers exits with this status while a previous instance still
/// holds the single-instance lock, which happens during a Hammerspoon 2 reload.
export const lockHeldStatus = 75;
const launchRetrySeconds = 5;
const requestTimeoutSeconds = 15;

export interface Hello {
  protocolVersion: number;
  trusted: boolean;
}

interface Pending {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: HSTimer;
}

type Launch = {hello: Hello} | {status: number; reason: string};

/** The executable's path, or a function that finds it at each launch and throws when it is missing. */
export type ProvidersPath = string | (() => string);

export class Pipe {
  readonly timers: Timers;
  task: HSTask | null = null;
  retiring: HSTask | null = null;
  private readonly hs: HS;
  private readonly path: ProvidersPath;
  private readonly args: string[];
  private readonly failure: (error: Error) => void;
  private readonly pending = new Map<number, Pending>();
  private sequence = 0;
  private buffer = "";

  constructor(hs: HS, path: ProvidersPath, failure: (error: Error) => void, args: string[] = []) {
    this.hs = hs;
    this.path = path;
    this.failure = failure;
    this.args = args;
    this.timers = new Timers(hs);
  }

  get running(): boolean {
    return !!(this.task?.isRunning || this.retiring?.isRunning);
  }

  async start(): Promise<Hello> {
    if (this.task) throw new Error("Providers are already running");
    for (let n = 0; this.retiring?.isRunning && n < 100; n++) await this.timers.sleep(0.02);
    if (this.retiring?.isRunning) throw new Error("Previous providers are still stopping");
    this.retiring = null;
    const began = Date.now();
    for (;;) {
      const outcome = await this.launch();
      if ("hello" in outcome) return outcome.hello;
      if (outcome.status !== lockHeldStatus || Date.now() - began > launchRetrySeconds * 1000)
        throw new Error("Providers exited before answering (" + outcome.status + ")");
      await this.timers.sleep(0.2);
    }
  }

  /** One launch attempt: the hello reply, or the exit that came first. */
  private launch(): Promise<Launch> {
    return new Promise<Launch>((resolve, reject) => {
      let settled = false;
      const settle = (outcome: Launch) => {
        if (settled) return;
        settled = true;
        resolve(outcome);
      };
      this.buffer = "";
      const path = typeof this.path === "function" ? this.path() : this.path;
      const task: HSTask = this.hs.task.create(
        path,
        this.args,
        (code, reason) => {
          if (this.task !== task) return;
          if (!settled) {
            this.stop(new Error("Providers exited before answering"));
            settle({status: code, reason});
            return;
          }
          this.fail(
            new Error(
              "Providers exited (" +
                code +
                ", " +
                reason +
                "). An interrupted action may have completed; inspect your Desktop before resuming.",
            ),
          );
        },
        null,
        (channel, text) => {
          if (this.task !== task) return;
          if (channel === "stdout") this.receive(text);
          else console.error("atelier-providers: " + text);
        },
      );
      this.task = task;
      if (!task.start()) {
        this.task = null;
        reject(new Error("Could not start atelier-providers at " + path));
        return;
      }
      this.request("hello").then(
        (reply) => {
          const hello = reply as Hello;
          if (hello.protocolVersion !== protocolVersion) {
            this.stop();
            reject(new Error("Atelier and atelier-providers versions do not match"));
            return;
          }
          settle({hello});
        },
        (error: Error) => {
          if (!settled) {
            settled = true;
            reject(error);
          }
        },
      );
    });
  }

  request(command: string, args: object = {}): Promise<unknown> {
    if (!this.task) return Promise.reject(new Error("Providers are stopped"));
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      const timer = this.timers.after(requestTimeoutSeconds, () =>
        this.fail(
          new Error(
            "Providers timed out. The action may have completed; inspect your Desktop before resuming.",
          ),
        ),
      );
      this.pending.set(id, {resolve, reject, timer});
      try {
        this.task?.sendInput(JSON.stringify({...args, id, command}) + "\n");
      } catch (error) {
        this.fail(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  receive(text: string): void {
    this.buffer += text;
    if (this.buffer.length > 1048576) {
      this.fail(new Error("Providers response exceeded its size limit"));
      return;
    }
    while (this.buffer.includes("\n")) {
      const end = this.buffer.indexOf("\n"),
        line = this.buffer.slice(0, end);
      this.buffer = this.buffer.slice(end + 1);
      if (!line.trim()) continue;
      let response: {id: number; ok: boolean; result?: unknown; error?: string};
      try {
        response = JSON.parse(line);
        if (!Number.isInteger(response.id) || typeof response.ok !== "boolean")
          throw new Error("Invalid response envelope");
      } catch (_) {
        this.fail(new Error("Malformed providers response; the operation outcome is unknown"));
        return;
      }
      const pending = this.pending.get(response.id);
      if (!pending) continue;
      this.pending.delete(response.id);
      this.timers.remove(pending.timer);
      if (response.ok) pending.resolve(response.result);
      else pending.reject(new Error(response.error || "Provider operation failed"));
    }
  }

  fail(error: Error): void {
    this.stop(error);
    this.failure(error);
  }

  stop(error: Error = new Error("Atelier stopped")): void {
    const task = this.task;
    this.task = null;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    this.timers.stop();
    this.buffer = "";
    if (task) {
      this.retiring = task;
      task.terminate();
    }
  }
}
