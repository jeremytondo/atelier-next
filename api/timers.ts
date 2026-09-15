// Timers owned by one session. Stopping cancels every pending sleep so an
// action awaiting a delay unwinds instead of resuming against a dead session.
import type {HS} from "./hs.ts";

export class Timers {
  private readonly hs: HS;
  private readonly items = new Map<HSTimer, () => void>();

  constructor(hs: HS) {
    this.hs = hs;
  }

  after(seconds: number, callback: () => void, cancel: () => void = () => {}): HSTimer {
    const timer: HSTimer = this.hs.timer.doAfter(seconds, () => {
      this.items.delete(timer);
      callback();
    });
    this.items.set(timer, cancel);
    return timer;
  }

  remove(timer: HSTimer | null | undefined): void {
    if (timer) {
      timer.stop();
      this.items.delete(timer);
    }
  }

  sleep(seconds: number): Promise<void> {
    return new Promise((resolve, reject) =>
      this.after(seconds, resolve, () => reject(new Error("Atelier stopped"))),
    );
  }

  stop(): void {
    const items = [...this.items];
    this.items.clear();
    for (const [timer, cancel] of items) {
      timer.stop();
      cancel();
    }
  }
}
