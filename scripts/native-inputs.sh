#!/usr/bin/env bash
# The exact input key that permits skipping native compilation when a
# matching output receipt exists. TypeScript, tests, and resources do not
# affect it.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"
[[ $# == 0 ]] || { echo 'usage: native-inputs.sh' >&2; exit 2; }
paths=(providers/Package.swift providers/Sources companion/Package.swift companion/Sources companion/App/Atelier.xcodeproj/project.pbxproj companion/App/Atelier.xcodeproj/xcshareddata companion/App/Atelier.xcconfig companion/App/Info.plist companion/App/Sources .xcodebuildmcp/config.yaml scripts/build-native.sh scripts/toolchain.sh mise.toml mise/tasks.toml scripts/tree-digest.sh scripts/build-state.sh scripts/with-lock.sh scripts/native-inputs.sh)
{
  "$root/scripts/tree-digest.sh" "$root" "${paths[@]}"
  "$root/scripts/toolchain.sh"
} | shasum -a 256 | awk '{print $1}'
