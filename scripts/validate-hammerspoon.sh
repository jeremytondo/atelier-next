#!/usr/bin/env bash
# Portable validation shared by resolution, cask generation, and publication.
# The ZIP checksum and exact download location bind each artifact to its pin.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# == 2 || $# == 3 ]] || die 'usage: validate-hammerspoon.sh PIN.json ARTIFACT.json [ZIP]'
jq -e --slurpfile pin "$1" --arg repo "$repository" '
  .schema == 1 and .pin == $pin[0] and
  (.pin.revision | test("^[0-9a-f]{40}$")) and (.pin.sha256 | test("^[0-9a-f]{64}$")) and
  (.pin.build | test("^[0-9]+(\\.[0-9]+){0,2}$")) and (.sha256 | test("^[0-9a-f]{64}$")) and
  (if .pin.release == null then
    .kind == "snapshot" and (.inputs | test("^[0-9a-f]{64}$")) and
    .tag == ("hs2-" + .inputs) and .version == (.pin.build + "," + .inputs) and
    .url == ("https://github.com/" + $repo + "/releases/download/" + .tag + "/Hammerspoon.2.zip") and
    .notarized == true and .architecture == "arm64"
  else
    .kind == "upstream" and (.pin.release.tag | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    .tag == .pin.release.tag and .version == .tag and .sha256 == .pin.release.sha256 and
    .url == ("https://github.com/cmsj/Hammerspoon2/releases/download/" + .tag + "/Hammerspoon.2.zip")
  end)' "$2" > /dev/null || die 'HS2 artifact does not match the pin or expected download.'
if [[ $# == 3 ]]; then
  [[ -s $3 && $(shasum -a 256 "$3" | awk '{print $1}') == "$(jq -r .sha256 "$2")" ]] || die 'HS2 ZIP checksum mismatch.'
fi
