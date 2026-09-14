// Keep native build/run ownership in XcodeBuildMCP; never retry failed commands.
"use strict";
const {spawnSync} = require("node:child_process");
const result = spawnSync("xcodebuildmcp", ["swift-package", "run", "--package-path", __dirname,
  "--executable-name", "wmbridge-experiment", "--timeout", "20", "--output", "json",
  "--json", JSON.stringify({arguments:process.argv.slice(2)})], {encoding:"utf8", maxBuffer:8 * 1024 * 1024});
if (result.error) throw result.error;
try {
  const response = JSON.parse(result.stdout);
  if (response.didError) {
    process.stdout.write(JSON.stringify(response, null, 2) + "\n");
  } else {
    process.stdout.write(response.data.output.stdout.join("\n") + "\n");
    process.stderr.write("XcodeBuildMCP log: " + response.data.artifacts.buildLogPath + "\n");
  }
} catch (_) { process.stdout.write(result.stdout); process.stderr.write(result.stderr); }
process.exitCode = result.status ?? 1;
