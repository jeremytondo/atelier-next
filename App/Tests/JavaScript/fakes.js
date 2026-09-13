"use strict";
// Small fakes of the HS2 boundaries used by Atelier; no macOS state is touched.
function fakeHS() {
  const tasks = [], timers = [], keys = [], watched = [];
  const snapshot = {trusted:true, focused:0, targetDisplay:"Main", missionControl:false, displays:[{id:"Main",current:"1",spaces:[{id:"1",fullscreen:false}]}],windows:[]};
  const state = {tasks, timers, keys, watched, snapshot, replies:true, trusted:true, failBinding:null, requests:[]};
  const timer = callback => { const value = {callback, stopped:false, stop() { this.stopped = true; }}; timers.push(value); return value; };
  const hs = {
    timer:{doAfter:(_, callback) => timer(callback), doEvery:(_, callback) => timer(callback)},
    task:{create(path, args, ended, _, output) {
      const task = {path, args, isRunning:false, output, ended,
        start() { this.isRunning = true; return this; },
        terminate() { this.isRunning = false; },
        sendInput(line) {
          const request = JSON.parse(line); state.requests.push(request);
          if (!state.replies) return;
          let result;
          if (request.command === "hello") result = {protocolVersion:1,trusted:state.trusted};
          else if (request.command === "quickResolve") result = {bundleID:"app." + request.app,name:request.app};
          else result = JSON.parse(JSON.stringify(snapshot));
          queueMicrotask(() => output("stdout", JSON.stringify({id:request.id,ok:true,result}) + "\n"));
        }};
      tasks.push(task); return task;
    }},
    hotkey:{assignable:() => true, getHotkeys:() => keys.filter(k => k.enabled), create(mods, name, callback) {
      const key = {mods,key:name,callback,enabled:false,destroyed:false,
        enable() { if (name === state.failBinding) return false; this.enabled = true; return true; },
        disable() { this.enabled = false; }, destroy() { this.disable(); this.destroyed = true; }};
      keys.push(key); return key;
    }},
    application:{fromPID:() => null}, window:{focusedWindow:() => null},
    ax:{addWatcher:(...args) => watched.push(args), removeWatcher:() => {}},
    notify:{show:() => {}}, reload:() => { state.reloaded = true; },
  };
  return {hs, state};
}
module.exports = {fakeHS};
