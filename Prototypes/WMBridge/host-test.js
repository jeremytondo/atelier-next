"use strict";
// Loaded only by a private copy of Atelier's headless --self-test entry point.
// No user config, global shortcuts, defaults startup, or preference writes.
module.exports = async function run(hs, options) {
  const {Bridge, Timers} = require(options.bridgeModule);
  const {TrialController} = require(options.controllerModule);
  const report = {host:"Atelier HS2 --self-test + actual AtelierEngine event loop",options};
  const timers = new Timers(hs);
  const bridge = new Bridge(hs,options.helper,error=>{report.helperFailure=error.message;},["serve",options.stateDirectory,"--disposable-session"]);
  globalThis.ate40Bridge = bridge;
  try {
    report.hello = await bridge.start();
    report.probe = await bridge.request("wmbridgeProbe");
    report.before = await bridge.request("snapshot");
    const controller = new TrialController(bridge), start = hs.timer.absoluteTime();
    if (options.action === "create") {
      report.result = await controller.create(options.runDirectory,options.enter === true);
    } else if (options.action === "enter") {
      report.result = await controller.enter({status:"previously-created-verified",createdID:options.createdID});
    } else if (options.action === "cleanup") {
      report.result = await bridge.request("wmbridgeCleanup",{runDirectory:options.runDirectory});
    } else { report.result = {status:"read-only"}; }
    report.inputToResultMilliseconds = (hs.timer.absoluteTime() - start) / 1e6;
    if (options.returnToBaseline && report.result.activation === "active-ID-verified") {
      const original = report.before.displays.find(d=>d.id===report.before.targetDisplay);
      const number = original.spaces.filter(s=>!s.fullscreen).findIndex(s=>s.id===original.current)+1;
      report.returned = await bridge.request("switch",{display:original.id,current:report.result.createdID,number});
    }
    report.after = await bridge.request("snapshot");
  } catch (error) { report.error = error.message; }
  finally {
    bridge.stop();
    for (let n=0; bridge.retiring?.isRunning && n<100; n++) await timers.sleep(0.02);
    report.helperStopped = !bridge.retiring?.isRunning;
    timers.stop();
    if (!hs.fs.write(options.output,JSON.stringify(report,null,2))) throw new Error("Could not write host evidence");
  }
  if (report.error) throw new Error(report.error);
};
