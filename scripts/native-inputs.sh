#!/usr/bin/env bash
# Exact input keys permit skipping compilation only with a matching output
# receipt. JS/resources do not affect the host key; bundle probes always rerun.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"
kind=${1:?usage: native-inputs.sh prepare|host|helpers}
common=(scripts/tree-digest.sh scripts/build-state.sh scripts/with-lock.sh scripts/native-inputs.sh)
integration=(App/Hammerspoon/upstream.json App/Hammerspoon/*.patch App/Hammerspoon/Shell App/Hammerspoon/ShellCore App/Hammerspoon/IPC App/Hammerspoon/Atelier.xcscheme)
case "$kind" in
  prepare) paths=("${integration[@]}" scripts/prepare-hammerspoon.sh "${common[@]}") ;;
  host) paths=("${integration[@]}" .xcodebuildmcp/config.yaml scripts/prepare-hammerspoon.sh scripts/build-hammerspoon.sh scripts/toolchain.sh scripts/timed.sh mise.toml "${common[@]}") ;;
  helpers) paths=(App/Package.swift App/Package.resolved App/Sources App/Hammerspoon/ShellCore .xcodebuildmcp/config.yaml scripts/build-helpers.sh scripts/toolchain.sh scripts/timed.sh mise.toml "${common[@]}") ;;
  *) exit 2 ;;
esac
{
  "$root/scripts/tree-digest.sh" "$root" "${paths[@]}"
  if [[ $kind != prepare ]]; then "$root/scripts/toolchain.sh"; fi
} | shasum -a 256 | awk '{print $1}'
