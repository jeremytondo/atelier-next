// Record one explicit trial; capture and mutation each run once. Native stdout
// and timing stay beside the movie. This requires an already disposable session.
"use strict";
const {spawn} = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const {setTimeout:delay} = require("node:timers/promises");

async function main() {
  const [movie, ...args] = process.argv.slice(2);
  if (!movie || !args.length || !args.includes("--disposable-session")) throw new Error("Usage: record.js /private/capture.mov create /new/run DISPLAY --disposable-session");
  if (!path.isAbsolute(movie) || fs.existsSync(movie)) throw new Error("Use a new absolute movie path");
  process.umask(0o077);
  const started = performance.now();
  const timing = {recordingRequestedUTC:new Date().toISOString(), requestedDurationSeconds:12};
  const recorder = spawn("/usr/sbin/screencapture", ["-v", "-V12", "-D1", movie], {stdio:["ignore", "ignore", "pipe"]});
  timing.recorderPID = recorder.pid;
  let recorderDone = false, captureErrors = "";
  recorder.stderr.on("data", data => { captureErrors += data; });
  const captured = new Promise((resolve, reject) => {
    recorder.on("error", reject);
    recorder.on("exit", code => { recorderDone = true; resolve(code); });
  });
  await delay(2000);
  if (recorderDone) throw new Error("Recording stopped before mutation: " + captureErrors);
  timing.invocationAfterRecordingRequestMilliseconds = performance.now() - started;
  timing.invocationUTC = new Date().toISOString();
  const isHost = args[0] === "host";
  const child = spawn(process.execPath, [path.join(__dirname, isHost ? "host.js" : "run.js"), ...(isHost ? args.slice(1) : args)], {stdio:["ignore", "pipe", "inherit"]});
  let output = "";
  child.stdout.on("data", data => { output += data; });
  const code = await new Promise((resolve, reject) => { child.on("exit", resolve); child.on("error", reject); });
  timing.resultAfterRecordingRequestMilliseconds = performance.now() - started;
  timing.commandExitCode = code;
  timing.recorderExitCode = await captured;
  timing.captureDiagnostics = captureErrors;
  fs.writeFileSync(movie + ".result.json", output, {flag:"wx", mode:0o600});
  fs.writeFileSync(movie + ".timing.json", JSON.stringify(timing, null, 2) + "\n", {flag:"wx", mode:0o600});
  process.stdout.write(output);
  console.error("Recording: " + movie);
  process.exitCode = code || timing.recorderExitCode || 0;
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
