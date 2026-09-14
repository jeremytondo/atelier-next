#!/usr/bin/env bash
# Serialize SwiftPM Debug tests and Release builds in their shared build tree.
# Only the three Release executables are retained for verified assembly reuse.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ ${1:-} != --locked ]]; then
  exec "$root/scripts/with-lock.sh" "$root/.build/locks/helpers" "$0" --locked "$@"
fi
shift
if [[ ${1:-} == --test ]]; then
  exec "$root/scripts/timed.sh" native-test xcodebuildmcp swift-package test --package-path "$root/App" --configuration debug
fi
# shellcheck source=scripts/build-state.sh
source "$root/scripts/build-state.sh"
inputs=$("$root/scripts/native-inputs.sh" helpers)
output="$root/.build/native/helpers"
receipt="$root/.build/native/helpers.json"
if receipt_valid "$output" "$receipt" "$inputs"; then
  echo 'Release helpers verified; compilation reused.'
  exit 0
fi
[[ ${1:-} != --verify ]] || { echo 'Helper output missing, stale, or corrupted; run mise run helpers:build.' >&2; exit 1; }
"$root/scripts/timed.sh" helpers-build xcodebuildmcp swift-package build --package-path "$root/App" --configuration release --architectures arm64
mkdir -p "$root/.build/native"
stage=$(mktemp -d "$root/.build/native/helpers-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
for executable in atelier-config atelier-engine atelier-tools; do
  binary="$root/App/.build/release/$executable"
  test -x "$binary"
  [[ $(lipo -archs "$binary") == arm64 ]]
  cp "$binary" "$stage/$executable"
done
[[ $("$root/scripts/native-inputs.sh" helpers) == "$inputs" ]] || { echo 'Helper inputs changed during compilation; retry.' >&2; exit 1; }
rm -f "$receipt"
replace_directory "$stage" "$output"
write_receipt "$output" "$receipt" "$inputs"
