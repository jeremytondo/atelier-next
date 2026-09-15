#!/usr/bin/env bash
# The exact input key that permits skipping providers compilation when a
# matching output receipt exists. TypeScript and resources do not affect it.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"
[[ ${1:?usage: native-inputs.sh providers} == providers ]] || exit 2
paths=(providers/Package.swift providers/Sources .xcodebuildmcp/config.yaml scripts/build-providers.sh scripts/toolchain.sh mise.toml mise/tasks.toml scripts/tree-digest.sh scripts/build-state.sh scripts/with-lock.sh scripts/native-inputs.sh)
{
  "$root/scripts/tree-digest.sh" "$root" "${paths[@]}"
  "$root/scripts/toolchain.sh"
} | shasum -a 256 | awk '{print $1}'
