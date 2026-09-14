"use strict";
// Bounded JSON-lines requests to one owned helper. A lost response has an unknown
// outcome: stop the session and never replay mutations automatically.
class Timers {
  constructor(hs) {
    this.hs = hs;
    this.items = new Map();
  }
  after(seconds, callback, cancel = () => {}) {
    let timer;
    timer = this.hs.timer.doAfter(seconds, () => {
      this.items.delete(timer);
      callback();
    });
    this.items.set(timer, cancel);
    return timer;
  }
  remove(timer) {
    if (timer) {
      timer.stop();
      this.items.delete(timer);
    }
  }
  sleep(seconds) {
    return new Promise((resolve, reject) =>
      this.after(seconds, resolve, () => reject(new Error("Atelier stopped"))),
    );
  }
  stop() {
    const items = [...this.items];
    this.items.clear();
    for (const [timer, cancel] of items) {
      timer.stop();
      cancel();
    }
  }
}
class Bridge {
  constructor(hs, path, failure, args = []) {
    this.hs = hs;
    this.path = path;
    this.failure = failure;
    this.timers = new Timers(hs);
    this.pending = new Map();
    this.sequence = 0;
    this.task = null;
    this.retiring = null;
    this.buffer = "";
    this.args = args;
  }
  async start() {
    if (this.task) throw new Error("Helper is already running");
    for (let n = 0; this.retiring?.isRunning && n < 100; n++) await this.timers.sleep(0.02);
    if (this.retiring?.isRunning)
      throw new Error("Previous helper is still stopping; try Resume again");
    this.retiring = null;
    this.buffer = "";
    const task = this.hs.task.create(
      this.path,
      this.args,
      (code, reason) => {
        if (this.task === task)
          this.fail(
            new Error(
              "Helper exited (" +
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
        else console.error("Atelier helper: " + text);
      },
    );
    this.task = task;
    if (!task?.start()) {
      this.task = null;
      throw new Error("Could not start the bundled helper");
    }
    const hello = await this.request("hello");
    if (hello.protocolVersion !== 2) throw new Error("App and helper versions do not match");
    return hello;
  }
  request(command, args = {}) {
    if (!this.task) return Promise.reject(new Error("Helper is stopped"));
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      const timer = this.timers.after(15, () =>
        this.fail(
          new Error(
            "Helper timed out. The action may have completed; inspect your Desktop before resuming.",
          ),
        ),
      );
      this.pending.set(id, {resolve, reject, timer});
      try {
        this.task.sendInput(JSON.stringify({...args, id, command}) + "\n");
      } catch (error) {
        this.fail(error);
      }
    });
  }
  receive(text) {
    this.buffer += text;
    if (this.buffer.length > 1048576) {
      this.fail(new Error("Helper response exceeded its size limit"));
      return;
    }
    while (this.buffer.includes("\n")) {
      const end = this.buffer.indexOf("\n"),
        line = this.buffer.slice(0, end);
      this.buffer = this.buffer.slice(end + 1);
      if (!line.trim()) continue;
      let response;
      try {
        response = JSON.parse(line);
        if (!Number.isInteger(response.id) || typeof response.ok !== "boolean")
          throw new Error("Invalid response envelope");
      } catch (_) {
        this.fail(new Error("Malformed helper response; the operation outcome is unknown"));
        return;
      }
      const pending = this.pending.get(response.id);
      if (!pending) continue;
      this.pending.delete(response.id);
      this.timers.remove(pending.timer);
      if (response.ok) pending.resolve(response.result);
      else pending.reject(new Error(response.error || "Native operation failed"));
    }
  }
  fail(error) {
    this.stop(error);
    this.failure(error);
  }
  stop(error = new Error("Atelier stopped")) {
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
module.exports = {Timers, Bridge};
