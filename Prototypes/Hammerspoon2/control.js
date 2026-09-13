"use strict";

// Local, fixed-command test transport. The released hs2 XPC CLI does not connect
// on the test Mac. This never evaluates JavaScript supplied by a client.
const benchFocus = require("./FocusBench.js");

module.exports = function control(atelier, directory) {
  const requestPath = directory + "/request.json", responsePath = directory + "/response.json";
  let busy = false;
  // Never replay a command left behind before config reload.
  let lastID = null;
  if (hs.fs.exists(requestPath)) {
    try { lastID = JSON.parse(hs.fs.read(requestPath, 0, 0)).id; } catch (_) {}
  }
  return hs.timer.doEvery(0.1, async () => {
    if (busy || !hs.fs.exists(requestPath)) return;
    let r;
    try { r = JSON.parse(hs.fs.read(requestPath, 0, 0)); } catch (_) { return; }
    if (!r.id || r.id === lastID) return;
    lastID = r.id; busy = true;
    try {
      let result;
      switch (r.command) {
        case "probe": result = await atelier.probe(); break;
        case "quickApps": result = atelier.quickApps(); break;
        case "quickApp": result = await atelier.quickApp(r.app); break;
        case "overlayStatus": result = atelier.overlayStatus(); break;
        case "group": result = await atelier.group(); break;
        case "select": result = await atelier.select(r.number); break;
        case "cycle": result = await atelier.cycle(r.offset); break;
        case "reorderMember": result = await atelier.reorderMember(r.offset); break;
        case "space": result = await atelier.space(r.action, r.args || {}); break;
        case "move": result = await atelier.move(r.number, !!r.follow); break;
        case "fillMode": result = atelier.setFill(r.mode); break;
        case "benchFocus": result = await benchFocus(atelier, hs, r.rounds || 3); break;
        case "status": result = {groups:[...atelier.store.groups.values()], metrics:atelier.metrics,
          lastError:atelier.lastError, lastResult:atelier.lastResult}; break;
        case "stop": result = atelier.stop(); break;
        case "start": await atelier.start(); result = "started"; break;
        default: throw new Error("Unknown prototype command");
      }
      hs.fs.write(responsePath, JSON.stringify({id:r.id, ok:true, result:result ?? null}), false);
    } catch (e) {
      hs.fs.write(responsePath, JSON.stringify({id:r.id, ok:false, error:String(e)}), false);
    } finally { busy = false; }
  });
};
