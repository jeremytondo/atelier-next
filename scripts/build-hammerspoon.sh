#!/usr/bin/env bash
# Keep the original HS2 target and dependency lockfile; Xcode builds its complete
# bundle so its resources, frameworks, and XPC service remain intact.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ ${1:-} != --locked ]]; then
  exec "$root/scripts/with-lock.sh" "$root/.build/locks/host" "$0" --locked "$@"
fi
shift
# shellcheck source=scripts/build-state.sh
source "$root/scripts/build-state.sh"
inputs=$("$root/scripts/native-inputs.sh" host)
output="$root/.build/native/host"
receipt="$root/.build/native/host.json"
if receipt_valid "$output" "$receipt" "$inputs"; then
  echo 'HS2 output verified; compilation reused.'
  exit 0
fi
[[ ${1:-} != --verify ]] || { echo 'HS2 output missing, stale, or corrupted; run mise run hs2:build.' >&2; exit 1; }
"$root/scripts/timed.sh" prepare "$root/scripts/prepare-hammerspoon.sh" --locked
"$root/scripts/timed.sh" host-build xcodebuildmcp macos build --project-path "$root/.build/hammerspoon2/Hammerspoon 2.xcodeproj" \
  --scheme Atelier --configuration Release --arch arm64 \
  --derived-data-path "$root/.build/hs2-derived" \
  --extra-args CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution -showBuildTimingSummary
app="$root/.build/hs2-derived/Build/Products/Release/Hammerspoon 2.app"
for executable in 'MacOS/Hammerspoon 2' MacOS/hs2 XPCServices/HammerspoonOSAScriptHelper.xpc/Contents/MacOS/HammerspoonOSAScriptHelper; do
  test -x "$app/Contents/$executable"
  [[ $(lipo -archs "$app/Contents/$executable") == arm64 ]]
done
test -s "$app/Contents/Info.plist"
test -d "$app/Contents/Resources"
mkdir -p "$root/.build/native"
stage=$(mktemp -d "$root/.build/native/host-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Hammerspoon 2.app"
cp "$root/.build/hammerspoon2/LICENSE" "$stage/Hammerspoon2-LICENSE"
mkdir "$stage/Licenses"
for dependency in AXSwift javascript-core-extras swift-commandlinekit xctest-dynamic-overlay; do
  cp "$root/.build/hs2-derived/SourcePackages/checkouts/$dependency/LICENSE" "$stage/Licenses/$dependency.txt"
  test -s "$stage/Licenses/$dependency.txt"
done
[[ $("$root/scripts/native-inputs.sh" host) == "$inputs" ]] || { echo 'Host inputs changed during compilation; retry.' >&2; exit 1; }
rm -f "$receipt"
replace_directory "$stage" "$output"
write_receipt "$output" "$receipt" "$inputs"
