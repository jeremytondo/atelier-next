#!/usr/bin/env bash
# Serialize SwiftPM Debug tests and Release builds in their shared build tree.
# Only the Release executable is retained, with a receipt, for reuse by packaging.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ ${1:-} != --locked ]]; then
  exec "$root/scripts/with-lock.sh" "$root/.build/locks/providers" "$0" --locked "$@"
fi
shift
if [[ ${1:-} == --test ]]; then
  exec xcodebuildmcp swift-package test --package-path "$root/providers" --configuration debug
fi
# shellcheck source=scripts/build-state.sh
source "$root/scripts/build-state.sh"
inputs=$("$root/scripts/native-inputs.sh" providers)
output="$root/.build/native/providers"
receipt="$root/.build/native/providers.json"
if receipt_valid "$output" "$receipt" "$inputs"; then
  echo 'Release providers verified; compilation reused.'
  exit 0
fi
[[ ${1:-} != --verify ]] || { echo 'Providers output missing, stale, or corrupted; run mise run providers:build.' >&2; exit 1; }
xcodebuildmcp swift-package build --package-path "$root/providers" --configuration release --architectures arm64
mkdir -p "$root/.build/native"
stage=$(mktemp -d "$root/.build/native/providers-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
binary="$root/providers/.build/release/atelier-providers"
# macOS bash 3.2 does not apply errexit to a failing [[ ]], so fail explicitly.
[[ -x $binary ]] || { echo "Missing build output: $binary" >&2; exit 1; }
[[ $(lipo -archs "$binary") == arm64 ]] || { echo 'Expected an arm64-only providers executable.' >&2; exit 1; }
cp "$binary" "$stage/atelier-providers"
[[ $("$root/scripts/native-inputs.sh" providers) == "$inputs" ]] || { echo 'Providers inputs changed during compilation; retry.' >&2; exit 1; }
rm -f "$receipt"
replace_directory "$stage" "$output"
write_receipt "$output" "$receipt" "$inputs"
