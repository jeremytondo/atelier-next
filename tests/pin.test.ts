import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {test} from "node:test";

// The pin is read by the runtime build check, the type fetch, the dev-only HS2
// build, and cask generation; every field has one shape.
test("the Hammerspoon 2 pin names a revision, a source checksum, and a build number", () => {
  const pin = JSON.parse(readFileSync(new URL("../hammerspoon2.json", import.meta.url), "utf8"));
  assert.deepEqual(Object.keys(pin).sort(), ["build", "release", "revision", "sha256"]);
  assert.match(pin.revision, /^[0-9a-f]{40}$/);
  assert.match(pin.sha256, /^[0-9a-f]{64}$/);
  assert.match(pin.build, /^[0-9]+(\.[0-9]+){0,2}$/);
  if (pin.release !== null) {
    assert.deepEqual(Object.keys(pin.release).sort(), ["sha256", "tag"]);
    assert.match(pin.release.tag, /^[0-9]+\.[0-9]+\.[0-9]+$/);
    assert.match(pin.release.sha256, /^[0-9a-f]{64}$/);
  }
});
