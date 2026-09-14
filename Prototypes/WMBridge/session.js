// Optional warm helper, scoped to this workspace. Transport failures never
// fall back to another create request; the native journal owns reconciliation.
"use strict";
const fs = require("node:fs"), path = require("node:path"), net = require("node:net");
const {createHash} = require("node:crypto"), {spawnSync} = require("node:child_process");
const {setTimeout:delay} = require("node:timers/promises");
const workspace = path.resolve(__dirname, "../..");
const root = path.join(workspace, ".build/ate-40-manual");
const active = path.join(root, "prepared-helper.json");

function privatePath(file, directory = false) {
  const info = fs.lstatSync(file);
  if (info.uid !== process.getuid() || (info.mode & 0o077) ||
    (directory ? !info.isDirectory() : !info.isFile())) throw new Error("Prepared helper state must be private and owned by you");
}
function readActive() {
  if (!fs.existsSync(active)) return null;
  privatePath(root, true); privatePath(active);
  const record = JSON.parse(fs.readFileSync(active, "utf8"));
  if (typeof record.directory !== "string" || !path.isAbsolute(record.directory)) throw new Error("Invalid helper directory");
  privatePath(record.directory, true);
  return record;
}
function sourceHash() {
  const hash = createHash("sha256");
  function read(file) {
    const info = fs.lstatSync(file);
    if (info.isDirectory()) for (const name of fs.readdirSync(file).sort()) read(path.join(file, name));
    else if (info.isFile()) { hash.update(path.relative(workspace, file)); hash.update(fs.readFileSync(file)); }
    else throw new Error("Unexpected source symlink; stop the prepared helper before continuing");
  }
  for (const relative of ["Prototypes/WMBridge/Sources", "Prototypes/WMBridge/Package.swift", "App/Sources", "App/Package.swift"]) read(path.join(workspace, relative));
  return hash.digest("hex");
}
function hasStopped(record) {
  if (["stopped.json", "failed.json"].some(name => fs.existsSync(path.join(record.directory, name)))) return true;
  const identity = ["ready.json", "starting.json"].map(name => path.join(record.directory, name)).find(file => fs.existsSync(file));
  let pid;
  if (identity) {
    privatePath(identity);
    pid = JSON.parse(fs.readFileSync(identity, "utf8")).pid;
  } else {
    const launchPath = path.join(record.directory, "launch.json");
    if (!fs.existsSync(launchPath)) return false;
    privatePath(launchPath);
    const launch = JSON.parse(fs.readFileSync(launchPath, "utf8"));
    pid = launch.data?.artifacts?.processId;
    if (!pid && launch.didError) return true;
  }
  if (!Number.isInteger(pid) || pid <= 0) throw new Error("Invalid helper identity");
  try { process.kill(pid, 0); return false; }
  catch (error) { if (error.code === "ESRCH") return true; throw error; }
}
function exchange(socketPath, args, timeoutMilliseconds = 12_000) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let buffer = "", settled = false;
    function finish(error, value) {
      if (settled) return;
      settled = true; clearTimeout(timer); socket.destroy();
      if (error) reject(error); else resolve(value);
    }
    const timer = setTimeout(() => finish(new Error("Prepared helper timed out; inspect the trial. No retry was sent.")), timeoutMilliseconds);
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(JSON.stringify({arguments: args}) + "\n"));
    socket.on("error", error => finish(new Error("Prepared helper connection failed: " + error.message + ". No fallback was sent.")));
    socket.on("end", () => finish(new Error("Prepared helper disconnected; inspect the trial. No retry was sent.")));
    socket.on("data", data => {
      buffer += data;
      if (buffer.length > 8 * 1024 * 1024) { finish(new Error("Prepared helper response exceeded its size limit")); return; }
      if (!buffer.includes("\n")) return;
      try {
        const value = JSON.parse(buffer.trim());
        if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid response object");
        finish(null, value);
      } catch (_) { finish(new Error("Malformed prepared helper response; inspect the trial. No retry was sent.")); }
    });
  });
}
async function requestIfPrepared(args) {
  if (!["create-ready", "cleanup-ready"].includes(args[0])) return null;
  const record = readActive();
  if (!record) return null;
  // No request has been submitted. An expired session can use the ordinary CLI.
  if (hasStopped(record)) { clear(record); return null; }
  if (record.sourceHash !== sourceHash()) throw new Error("Native source changed. Run mise run desktop:stop, then mise run desktop:prepare before creating again.");
  const result = await exchange(path.join(record.directory, "control.sock"), args);
  return {...result, preparedHelper: true};
}
function clear(record) {
  if (readActive()?.directory === record.directory) fs.unlinkSync(active);
}
async function prepare() {
  fs.mkdirSync(root, {recursive: true, mode: 0o700}); privatePath(root, true);
  const previous = readActive();
  if (previous) {
    if (hasStopped(previous)) clear(previous);
    else {
      if (previous.sourceHash !== sourceHash()) throw new Error("Native source changed; run mise run desktop:stop before preparing again");
      const response = await exchange(path.join(previous.directory, "control.sock"), ["ping"]);
      console.log("Desktop helper is already ready (PID " + response.pid + ")."); return;
    }
  }
  process.umask(0o077);
  const directory = fs.mkdtempSync("/tmp/atelier-ate40-" + process.getuid() + "-");
  const record = {directory, sourceHash: sourceHash()};
  fs.writeFileSync(active, JSON.stringify(record), {flag: "wx", mode: 0o600});
  const launched = spawnSync("xcodebuildmcp", ["swift-package", "run", "--package-path", __dirname,
    "--executable-name", "wmbridge-experiment", "--background", "--output", "json", "--json",
    JSON.stringify({arguments: ["serve-ready", directory, "--disposable-session"]})], {encoding: "utf8", maxBuffer: 8 * 1024 * 1024});
  fs.writeFileSync(path.join(directory, "launch.json"), launched.stdout || "", {flag: "wx", mode: 0o600});
  if (launched.error) {
    if (["ENOENT", "EACCES"].includes(launched.error.code)) clear(record);
    throw new Error("Cannot launch the prepared helper: " + launched.error.message + "; inspect " + directory);
  }
  let launch;
  try { launch = JSON.parse(launched.stdout); }
  catch (_) { throw new Error("Unrecognized launch result; inspect " + directory + "/launch.json before preparing again"); }
  if (launch.didError || launched.status !== 0) {
    if (launch.didError && !launch.data?.artifacts?.processId) clear(record);
    throw new Error("Preparation failed; inspect " + directory + "/launch.json");
  }
  for (let attempt = 0; attempt < 200; attempt++) {
    const failure = path.join(directory, "failed.json");
    if (fs.existsSync(failure)) {
      const report = JSON.parse(fs.readFileSync(failure, "utf8"));
      clear(record);
      throw new Error(report.error);
    }
    if (hasStopped(record)) { clear(record); throw new Error("Helper exited during preparation; inspect " + directory + "/launch.json"); }
    if (fs.existsSync(path.join(directory, "ready.json"))) {
      if (record.sourceHash !== sourceHash()) throw new Error("Source changed during preparation; stop the helper and prepare again");
      const response = await exchange(path.join(directory, "control.sock"), ["ping"]);
      if (response.protocolVersion !== 1) throw new Error("Prepared helper protocol mismatch");
      console.log("Desktop helper ready (PID " + response.pid + "). The normal slide animation is unchanged.");
      console.log("Run: mise run desktop:create -- --enter");
      console.log("Stops after 10 idle minutes, or run: mise run desktop:stop");
      console.log("Session: " + directory);
      return;
    }
    await delay(100);
  }
  throw new Error("Preparation did not become ready; inspect " + directory + ". No Desktop was created.");
}
async function stop() {
  const record = readActive();
  if (!record) { console.log("No prepared Desktop helper."); return; }
  if (!hasStopped(record)) {
    const result = await exchange(path.join(record.directory, "control.sock"), ["stop"]);
    if (result.stopped !== true) throw new Error(result.error || "Helper stop was not confirmed");
    for (let attempt = 0; attempt < 100 && !hasStopped(record); attempt++) await delay(20);
    if (!hasStopped(record)) throw new Error("Helper acknowledged stop but has not exited; session record retained");
  }
  clear(record);
  console.log("Prepared helper stopped. Created Desktops remain owned by their trial journals.");
}
if (require.main === module) {
  const command = process.argv[2];
  (command === "prepare" ? prepare : command === "stop" ? stop : async () => { throw new Error("Usage: session.js prepare|stop"); })()
    .catch(error => { console.error(error.message); process.exitCode = 2; });
}
module.exports = {exchange, requestIfPrepared};
