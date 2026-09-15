// The installed package entry: `require("/opt/homebrew/share/atelier")` returns
// the atelier object. Tests never load this file; they compose the same pieces
// with fakes. `version.json` is written by packaging and absent in a checkout.
import {type AtelierAPI, createAPI} from "./api/index.ts";
import {createDefaults, type Defaults} from "./defaults/index.ts";

import pin = require("./hammerspoon2.json");

/** The API plus the defaults, as one object. */
interface Atelier extends AtelierAPI, Defaults {}

function installedVersion(): string {
  try {
    return (require("./version.json") as {version: string}).version;
  } catch (_) {
    return "unpackaged";
  }
}

const api = createAPI(hs, {providers: __dirname + "/atelier-providers"});
const defaults = createDefaults(hs, api, {expectedBuild: pin.build, version: installedVersion()});
const atelier: Atelier = {...api, ...defaults};
export = atelier;
