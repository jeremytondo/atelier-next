// Manual ATE-40 trials use the existing native experiment, one new journal per
// invocation. Optional entry uses one native adjacent action; never replay a
// failed request or infer that failure means no Desktop was created.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const {randomUUID} = require("node:crypto");
const {execFileSync} = require("node:child_process");

const help = `Usage:
  mise run desktop:create [-- /absolute/new-trial-directory]
  mise run desktop:create -- --enter
  mise run desktop:create -- --raw
  mise run desktop:create -- --check
  mise run desktop:status [-- /absolute/trial-directory]
  mise run desktop:diagnose -- /absolute/trial-directory
  mise run desktop:cleanup -- /absolute/trial-directory

Quit Atelier before creation or cleanup. Use your disposable GUI session with
one display. Creation uses ATE-40's WMBridge call and leaves the result in place
for manual switching. It briefly allocates a process-owned virtual display to
refresh Dock, checks that the original display modes return unchanged, and
places the new Desktop immediately after the current one. --enter also enters
it using the enabled native next-Desktop shortcut. No Mission Control is opened.
--raw runs only the original WMBridge call, without placement or Dock refresh.
New numbered shortcut registrations are not repaired; use adjacent switching
or Mission Control to reach Desktops beyond Dock's previously registered range.

Creation prints the saved trial path and commands to inspect or remove its ID.
--check, status, and diagnose are read only. After an error, inspect the trial before making
another create request. Cleanup requires switching away and closing saved test
windows on the created Desktop first. Reopen Atelier after finishing the trial.
`;

function native(args) {
  const output = execFileSync(process.execPath, [path.join(__dirname, "run.js"), ...args],
    {encoding: "utf8", maxBuffer: 8 * 1024 * 1024});
  const report = JSON.parse(output);
  if (report.didError || report.error && !report.status) throw new Error(output);
  return report;
}

function privateDirectory(directory) {
  const info = fs.lstatSync(directory);
  if (!info.isDirectory() || info.uid !== process.getuid() || (info.mode & 0o077)) {
    throw new Error("Trial directory must be owned by you, private (0700), and not a symlink");
  }
}

function save(directory, name, value) {
  fs.writeFileSync(path.join(directory, name), JSON.stringify(value, null, 2) + "\n",
    {mode: 0o600, flag: "wx"});
}

function quote(value) { return "'" + value.replaceAll("'", "'\\''") + "'"; }

function topology(report, log) {
  for (const display of report.after ?? report.censusAfter ?? []) {
    const current = display["Current Space"]?.id64;
    log(`Display: ${display["Display Identifier"]}`);
    log(`Current Space: ${current}`);
    log(`WindowServer Space list: ${(display.Spaces ?? []).map(space =>
      `${space.id64} (type ${space.type})`).join(", ")}`);
  }
  log("This list does not establish Mission Control visibility.");
}

function main(args, {invoke = native, log = console.log,
  root = path.resolve(__dirname, "../../.build/ate-40-manual")} = {}) {
  const enter = args.includes("--enter"), raw = args.includes("--raw");
  const positional = args.filter(arg => !["--enter", "--raw"].includes(arg));
  const [command, argument] = positional;
  if (args.includes("--help")) { log(help); return 0; }
  if (positional.length > 2 || (enter && raw) || ((enter || raw) && (command !== "create" || argument === "--check")) ||
    !["create", "status", "diagnose", "cleanup"].includes(command) ||
    (["cleanup", "diagnose"].includes(command) && !argument) ||
    (argument && !(command === "create" && argument === "--check") && !path.isAbsolute(argument))) {
    log(help); return 64;
  }

  if (command === "status" && !argument || command === "create" && argument === "--check") {
    const probe = invoke(["probe"]);
    topology(probe, log);
    log(`WMBridge creation API available: ${Boolean(probe.createABIAvailable)}`);
    log("Read-only probe; no Desktop creation requested.");
    return 0;
  }

  if (command !== "create") {
    const directory = path.resolve(argument);
    privateDirectory(directory);
    const report = invoke([command === "status" ? "reconcile" : command === "cleanup" ? "cleanup-ready" : command,
      path.join(directory, "creation"), ...(command === "cleanup" ? ["--disposable-session"] : [])]);
    const name = `${command}-${Date.now()}-${randomUUID()}.json`;
    save(directory, name, report);
    log(`Space ID: ${report.createdID ?? report.returnedID ?? "unknown"}`);
    log(`Result: ${report.status ?? "read-only reconciliation"}`);
    topology(report, log);
    if (command === "diagnose") {
      if (report.dockSpaceCount?.status === 0) log(`Dock's own Desktop count: ${report.dockSpaceCount.count}`);
      log(`Saved Desktop configuration IDs: ${report.savedSpaceIDs?.join(", ") ?? "unavailable"}`);
      log(`Returned ID in saved configuration: ${report.returnedIDInSavedConfiguration ?? "unknown"}`);
      log("Saved configuration can lag live state; the full report includes per-Space values and the read delegate trace.");
    }
    log(`Full report: ${path.join(directory, name)}`);
    if (command === "cleanup" && !["removed", "already-absent"].includes(report.status)) {
      log("Cleanup was not confirmed. Inspect the report before taking another action.");
      return 2;
    }
    return 0;
  }

  let directory;
  if (argument) {
    directory = path.resolve(argument);
    fs.mkdirSync(directory, {mode: 0o700}); // Existing attempts are never reusable.
  } else {
    fs.mkdirSync(root, {recursive: true, mode: 0o700});
    privateDirectory(root);
    directory = fs.mkdtempSync(path.join(root, "trial-"));
  }
  privateDirectory(directory);
  log(`Trial: ${directory}`);
  log(`Inspect: mise run desktop:status -- ${quote(directory)}`);
  log(`Cleanup: mise run desktop:cleanup -- ${quote(directory)}`);
  try {
    const probe = invoke(["probe"]);
    save(directory, "probe.json", probe);
    const displays = probe.censusAfter;
    if (probe.screens?.length !== 1 || displays?.length !== 1 ||
      typeof displays[0]["Display Identifier"] !== "string" || !displays[0]["Display Identifier"]) {
      throw new Error("Creation requires exactly one screen and one native display");
    }
    if (!probe.bridgeAnswered || !probe.bridgeMatchesCensus || !probe.createABIAvailable) {
      throw new Error("WMBridge capability probe failed; no creation requested");
    }
    log(`Creating once on ${probe.screens[0].name ?? "the current display"}…`);
    const report = invoke([raw ? "create" : "create-ready", path.join(directory, "creation"),
      displays[0]["Display Identifier"], "--disposable-session", ...(enter ? ["--enter"] : [])]);
    save(directory, "cli-result.json", report);
    log(`WMBridge returned Space ID: ${report.createdID ?? "unknown"}`);
    log(`Result: ${report.status}`);
    topology(report, log);
    if (report.error || ![raw ? "managed-type0-confirmed" : enter ? "native-entry-confirmed" : "dock-registration-confirmed"].includes(report.status)) {
      log("The requested flow was not confirmed. Inspect this trial before running create again.");
      return 2;
    }
    if (raw) log("Confirmed in WindowServer only. Left in place for your manual test.");
    else {
      log(`Dock's Desktop count: ${report.dockSpaceCount?.count ?? "unknown"}`);
      log(enter ? "Entered using the native next-Desktop shortcut." : "Ready immediately to the right of the current Desktop.");
      log("Use native adjacent switching or Mission Control; new numbered bindings may be unavailable.");
    }
    return 0;
  } catch (error) {
    save(directory, "cli-error.json", {error: error.message});
    log("Attempt stopped. Logs were preserved; no automatic retry or cleanup was requested.");
    throw error;
  }
}

if (require.main === module) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 2; }
}
module.exports = {main};
