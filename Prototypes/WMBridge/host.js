"use strict";
// Prepare a disposable copy of the installed HS2 host, then launch it through
// XcodeBuildMCP. Only the copy's self-test resource and environment are changed.
const fs = require("node:fs"), path = require("node:path"), {spawnSync} = require("node:child_process");
const [optionsFile] = process.argv.slice(2);
if (!optionsFile) throw new Error("Usage: host.js /private/options.json");
const options = JSON.parse(fs.readFileSync(optionsFile,"utf8"));
const processes = spawnSync("/bin/ps",["-axo","pid=,comm="],{encoding:"utf8"});
if (processes.status !== 0 || processes.stdout.split("\n").some(line=>line.trim().endsWith("/Atelier.app/Contents/MacOS/Atelier"))) {
  throw new Error("Quit the running Atelier instance before launching the isolated host");
}
if (options.disposableSession !== true) throw new Error("Explicit disposableSession:true is required");
if (!path.isAbsolute(options.stateDirectory) || (fs.statSync(options.stateDirectory).mode & 0o077)) throw new Error("Use a private absolute state directory");
if (fs.existsSync(options.output)) throw new Error("Evidence output already exists; refusing to replay");
const root = path.resolve(__dirname,"../.."), app = path.join(options.stateDirectory,"Atelier.app");
options.bridgeModule = path.join(root,"App/Resources/Atelier/bridge.js");
options.controllerModule = path.join(__dirname,"controller.js");
options.helper = path.join(__dirname,".build/debug/wmbridge-experiment");
function run(command,args) {
  const p=spawnSync(command,args,{stdio:"inherit"});
  if(p.error) throw p.error;
  if(p.status!==0) throw new Error(command+" exited "+p.status+"; do not replay the trial");
}
if (!fs.existsSync(app)) run("/usr/bin/ditto",["/Applications/Atelier.app",app]);
const resource=path.join(app,"Contents/Resources/Atelier/self-test.js");
fs.writeFileSync(resource,`globalThis.atelierSelfTestDone=false; globalThis.atelierSelfTestError=null;\nrequire(${JSON.stringify(path.join(__dirname,"host-test.js"))})(hs,${JSON.stringify(options)}).then(()=>{globalThis.atelierSelfTestDone=true;}).catch(error=>{globalThis.atelierSelfTestError=String(error);globalThis.atelierSelfTestDone=true;});\n`);
run("/usr/bin/plutil",["-replace","LSEnvironment","-json",JSON.stringify({ATELIER_CONFIG_DIR:options.stateDirectory}),path.join(app,"Contents/Info.plist")]);
run("/usr/bin/codesign",["--force","--sign","-","--preserve-metadata=entitlements,identifier,flags",app]);
run("xcodebuildmcp",["macos","launch","--app-path",app,"--json",JSON.stringify({launchArgs:["--self-test"]})]);
