"use strict";
// Installed-bundle probe of the real HS2 engine, module loader, timers and tasks.
// No user configuration, keyboard hooks, or window/Space mutations are involved.
globalThis.atelierSelfTestDone = false;
globalThis.atelierSelfTestError = null;
function fail(message) {
  globalThis.atelierSelfTestError = String(message);
  globalThis.atelierSelfTestDone = true;
}
try {
  if (
    typeof hs.hotkey.create !== "function" ||
    typeof hs.ax.applicationElement !== "function" ||
    typeof hs.canvas.create !== "function"
  )
    throw new Error("Required HS2 APIs are missing");
  if (atelier.defaults().bindings["desktop-1"] !== "option-1")
    throw new Error("Bundled defaults were not loaded");
  if (atelier.state !== "Paused") throw new Error("Defaults started without user configuration");
  globalThis.atelierSelfTestTimer = hs.timer.doAfter(0.01, () => {
    try {
      let output = "";
      globalThis.atelierSelfTestTask = hs.task.create(
        "/usr/bin/printf",
        ["atelier-hs2-probe"],
        (code) => {
          // Completion and stream callbacks may arrive in either order.
          globalThis.atelierSelfTestCompletion = hs.timer.doAfter(0.1, () => {
            if (code !== 0 || output !== "atelier-hs2-probe")
              fail("HS2 task output failed: " + code + ": " + output);
            else exerciseDefaults();
          });
        },
        null,
        (channel, text) => {
          if (channel === "stdout") output += text;
        },
      );
      if (!globalThis.atelierSelfTestTask.start()) fail("Could not start HS2 task");
    } catch (error) {
      fail(error);
    }
  });
} catch (error) {
  fail(error);
}

async function exerciseDefaults() {
  try {
    if (globalThis.atelierSelfTestXPC !== false) {
      const osa = await hs.osascript.applescript("return 2 + 2");
      if (!osa?.success || osa.result !== 4)
        throw new Error("Bundled AppleScript service failed: " + JSON.stringify(osa));
    }
    const {Timers} = require(atelierHost.modules + "/bridge.js");
    globalThis.atelierProbeTimers = new Timers(hs);
    globalThis.atelierProbe = require(atelierHost.modules + "/index.js").create(hs, {
      helper: atelierHost.helper,
      helperArguments: ["--self-test-helper"],
      bundleID: atelierHost.bundleID,
      version: "self-test",
    });
    await atelierProbe.start({
      spaces: false,
      groups: false,
      overlay: false,
      quickApps: [],
      bindings: {"reload-config": "none"},
    });
    if (atelierProbe.state !== "Running") throw new Error("Defaults startup failed");
    atelierProbe.stop();
    await atelierProbe.start();
    if (atelierProbe.state !== "Running") throw new Error("Defaults resume failed");
    atelierProbe.stop();
    for (let n = 0; atelierProbe.helperRunning() && n < 100; n++)
      await atelierProbeTimers.sleep(0.02);
    if (atelierProbe.helperRunning()) throw new Error("Probe helper did not stop");
    atelierProbeTimers.stop();
    globalThis.atelierSelfTestDone = true;
  } catch (error) {
    if (globalThis.atelierProbe) atelierProbe.stop();
    if (globalThis.atelierProbeTimers) atelierProbeTimers.stop();
    fail(error);
  }
}
