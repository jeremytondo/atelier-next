#!/usr/bin/env bash
# Serialize the native Debug tests and Release builds in their shared build
# trees. One Release output is retained, with a receipt, for reuse by
# packaging: an unsigned Atelier.app that already carries the providers
# executable beside the companion's own.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ ${1:-} != --locked ]]; then
  exec "$root/scripts/with-lock.sh" "$root/.build/locks/native" "$0" --locked "$@"
fi
shift
if [[ ${1:-} == --test ]]; then
  xcodebuildmcp swift-package test --package-path "$root/providers" --configuration debug
  exec xcodebuildmcp swift-package test --package-path "$root/companion" --configuration debug
fi
# shellcheck source=scripts/build-state.sh
source "$root/scripts/build-state.sh"
inputs=$("$root/scripts/native-inputs.sh")
output="$root/.build/native/app"
receipt="$root/.build/native/app.json"
if receipt_valid "$output" "$receipt" "$inputs"; then
  echo 'Release Atelier.app verified; compilation reused.'
  exit 0
fi
[[ ${1:-} != --verify ]] || { echo 'Native output missing, stale, or corrupted; run mise run native:build.' >&2; exit 1; }
xcodebuildmcp swift-package build --package-path "$root/providers" --configuration release --architectures arm64
# The bundle with its App Intents metadata is an Xcode build; packaging signs it.
xcodebuildmcp macos build --project-path "$root/companion/App/Atelier.xcodeproj" --scheme Atelier \
  --configuration Release --arch arm64 --derived-data-path "$root/.build/companion-derived"
mkdir -p "$root/.build/native"
stage=$(mktemp -d "$root/.build/native/app-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
providers="$root/providers/.build/release/atelier-providers"
app="$root/.build/companion-derived/Build/Products/Release/Atelier.app"
# macOS bash 3.2 does not apply errexit to a failing [[ ]], so fail explicitly.
[[ -x $providers ]] || { echo "Missing build output: $providers" >&2; exit 1; }
[[ -x $app/Contents/MacOS/Atelier && -f $app/Contents/Info.plist ]] || { echo "Missing build output: $app" >&2; exit 1; }
[[ -d $app/Contents/Resources/Metadata.appintents ]] || { echo 'The companion build carries no App Intents metadata; Spotlight would list no action.' >&2; exit 1; }
for binary in "$providers" "$app/Contents/MacOS/Atelier"; do
  [[ $(lipo -archs "$binary") == arm64 ]] || { echo "Expected an arm64-only executable: $binary" >&2; exit 1; }
done
cp -R "$app" "$stage/Atelier.app"
cp "$providers" "$stage/Atelier.app/Contents/MacOS/atelier-providers"
[[ $("$root/scripts/native-inputs.sh") == "$inputs" ]] || { echo 'Native inputs changed during compilation; retry.' >&2; exit 1; }
rm -f "$receipt"
replace_directory "$stage" "$output"
write_receipt "$output" "$receipt" "$inputs"
