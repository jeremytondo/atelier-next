"use strict";
// Diagnostic: measure how fast Hammerspoon 2 alone can focus an exact Group
// window, without the native helper. Cycles through the current Group's members
// with several pure-HS2 strategies and reports the verified focus latency.
module.exports = async function benchFocus(atelier, hs, rounds = 3) {
  const now = () => Date.now();
  const progressPath = __dirname + "/.runtime/focus-bench-progress.txt";
  let log = "";
  const progress = line => { log += now() + " " + line + "\n"; hs.fs.write(progressPath, log, false); };
  progress("start rounds=" + rounds + " setTimeout=" + typeof setTimeout);
  // HS2 drops unreferenced timers at garbage collection; retain until fired.
  // Timers must stay reachable from a global; HS2 otherwise collects them mid-await.
  const timers = globalThis.__atelierBenchTimers = new Set();
  const sleep = s => new Promise(resolve => {
    const timer = hs.timer.doEvery(s, () => { timer.stop(); timers.delete(timer); resolve(); });
    timers.add(timer);
  });
  const timed = fn => { const t = now(); const value = fn(); return {ms: now() - t, value}; };
  const focusedIs = m => { const f = hs.window.focusedWindow(); return !!f && f.id === m.id && f.pid === m.pid; };
  // One repeating timer per verification: HS2 loses callbacks when hundreds of
  // short one-shot timers are created in quick succession.
  function verify(member, limitMs = 600) {
    return new Promise(resolve => {
      const started = now();
      if (focusedIs(member)) return resolve({verified: true, ms: 0});
      const timer = hs.timer.doEvery(0.005, () => {
        const elapsed = now() - started;
        if (focusedIs(member)) { timer.stop(); timers.delete(timer); resolve({verified: true, ms: elapsed}); }
        else if (elapsed >= limitMs) { timer.stop(); timers.delete(timer); resolve({verified: false, ms: elapsed}); }
      });
      timers.add(timer);
    });
  }
  progress("group lookup");
  const group = [...atelier.store.groups.values()][0];
  if (!group || group.members.length < 2) throw new Error("Need a Group with at least two members");
  const members = group.members.map(m => ({id: m.id, pid: m.pid, app: m.app}));
  const original = hs.window.focusedWindow();
  const result = {members, rounds, overhead: {}, switches: []};
  progress("members=" + JSON.stringify(members));
  for (const name of ["allWindows", "orderedWindows", "focusedWindow"]) {
    const samples = [];
    for (let i = 0; i < 3; i++) { const t = timed(() => hs.window[name]()); samples.push(t.ms); }
    result.overhead[name] = samples;
  }
  const setAX = (el, name, value) => typeof el.setAttributeValue === "function" ? el.setAttributeValue(name, value)
    : typeof el.setAttributeValueValue === "function" ? el.setAttributeValueValue(name, value) : "unsupported";
  const appName = a => a && (a.name || a.title || a.localizedName || a.bundleID);
  const find = m => hs.window.allWindows().find(w => w.id === m.id && w.pid === m.pid);
  const strategies = {
    axFrontmostMainRaise: w => {
      const el = w.axElement();
      const app = (w.application && w.application.axElement && w.application.axElement()) || hs.ax.applicationElement(w.application);
      const front = app ? setAX(app, "AXFrontmost", true) : "no app element";
      const main = setAX(el, "AXMain", true);
      const raise = el.performAction("AXRaise");
      return {returned: [front, main, raise]};
    },
    focus: w => ({returned: w.focus()}),
    raiseFocus: w => { const r = w.raise(); return {returned: [r, w.focus()]}; },
    axMainRaiseActivate: w => {
      const el = w.axElement(); const app = w.application;
      const main = setAX(el, "AXMain", true);
      const raise = el.performAction("AXRaise");
      app.activate(false);
      return {returned: [main, raise]};
    },
    activateThenAxRaise: w => {
      const el = w.axElement(); const app = w.application;
      app.activate(false);
      const raise = el.performAction("AXRaise");
      const main = setAX(el, "AXMain", true);
      return {returned: [raise, main]};
    },
  };
  for (const [strategy, run] of Object.entries(strategies)) {
    for (let round = 0; round < rounds; round++) {
      for (const member of members) {
        if (focusedIs(member)) continue;
        const before = hs.window.focusedWindow();
        const lookup = timed(() => find(member));
        if (!lookup.value) { result.switches.push({strategy, to: member.app, error: "window not found"}); continue; }
        progress(strategy + " -> " + member.app + " lookup " + lookup.ms + "ms");
        let call;
        try { call = timed(() => run(lookup.value)); }
        catch (e) { progress("  strategy error " + e); result.switches.push({strategy, to: member.app, error: String(e)}); break; }
        progress("  called " + JSON.stringify(call.value.returned) + " in " + call.ms + "ms");
        const check = await verify(member);
        progress("  verified=" + check.verified + " " + check.ms + "ms");
        let truth = null;
        try { const snap = await atelier.probe(); truth = snap && snap.busy ? "busy" : snap.focused; } catch (e) { truth = String(e); }
        const front = hs.application.frontmost();
        progress("  helperFocused=" + truth + " frontmost=" + appName(front) + " isFocused=" + lookup.value.isFocused);
        result.switches.push({strategy, from: appName(before && before.application), to: member.app,
          lookupMs: lookup.ms, callMs: call.ms, verifyMs: check.ms, verified: check.verified,
          totalMs: lookup.ms + call.ms + check.ms, returned: call.value.returned, helperFocused: truth});
        await sleep(0.15);
      }
    }
  }
  progress("done");
  // HS2 0.0.12's focus() does not change focus; restore through the AX route.
  if (original) { try { strategies.axFrontmostMainRaise(original); } catch (_) {} }
  const summary = {};
  for (const s of result.switches) {
    const entry = summary[s.strategy] || (summary[s.strategy] = {n: 0, verified: 0, totals: []});
    entry.n++; if (s.verified) entry.verified++; entry.totals.push(s.totalMs);
  }
  for (const e of Object.values(summary)) {
    e.totals.sort((a, b) => a - b);
    e.minMs = e.totals[0]; e.medianMs = e.totals[Math.floor(e.totals.length / 2)]; e.maxMs = e.totals[e.totals.length - 1];
    delete e.totals;
  }
  result.summary = summary;
  hs.fs.write(__dirname + "/.runtime/focus-bench.json", JSON.stringify(result), false);
  return result;
};
