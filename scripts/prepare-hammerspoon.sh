#!/usr/bin/env bash
# Prepare verified, patched source without touching a matching tree. The host
# lock also protects Xcode readers; only a fully staged tree replaces old input.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ ${1:-} != --locked ]]; then
  exec "$root/scripts/with-lock.sh" "$root/.build/locks/host" "$0" --locked
fi
# shellcheck source=scripts/build-state.sh
source "$root/scripts/build-state.sh"
inputs=$("$root/scripts/native-inputs.sh" prepare)
source_dir="$root/.build/hammerspoon2"
receipt="$root/.build/prepared.json"
if receipt_valid "$source_dir" "$receipt" "$inputs"; then
  echo 'Prepared HS2 source verified; unchanged.'
  exit 0
fi
revision=$(jq -er .revision "$root/App/Hammerspoon/upstream.json")
checksum=$(jq -er .sha256 "$root/App/Hammerspoon/upstream.json")
[[ $revision =~ ^[0-9a-f]{40}$ && $checksum =~ ^[0-9a-f]{64}$ ]] || exit 1
mkdir -p "$root/.build/downloads"
stage=$(mktemp -d "$root/.build/hs2-prepare.XXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
archive="$root/.build/downloads/hs2-$revision.tar.gz"
if [[ ! -f $archive ]]; then
  temporary="$stage/download.tar.gz"
  "$root/scripts/timed.sh" upstream-download curl --fail --silent --show-error --location --retry 3 \
    "https://codeload.github.com/cmsj/Hammerspoon2/tar.gz/$revision" -o "$temporary"
  [[ $(shasum -a 256 "$temporary" | awk '{print $1}') == "$checksum" ]] || { echo 'HS2 archive checksum mismatch' >&2; exit 1; }
  mv "$temporary" "$archive"
fi
[[ $(shasum -a 256 "$archive" | awk '{print $1}') == "$checksum" ]] || { echo 'HS2 archive checksum mismatch' >&2; exit 1; }
mkdir "$stage/source"
tar -xzf "$archive" --strip-components=1 -C "$stage/source"
for patch_file in "$root"/App/Hammerspoon/*.patch; do
  patch --batch --fuzz=0 -d "$stage/source" -p1 < "$patch_file"
done
# Compose the application by exclusion. Missing shell inputs are an upgrade
# review signal; never silently keep a newly renamed upstream entry point.
shell="$stage/source/Hammerspoon 2"
for path in Lifecycle/Hammerspoon_2App.swift Managers/ManagerManager.swift Managers/SettingsManager.swift Windows/OnboardingView.swift Windows/Settings; do
  [[ -e "$shell/$path" ]] || { echo "Missing upstream shell input: $path" >&2; exit 1; }
  rm -rf "${shell:?}/${path:?}"
done
mkdir "$shell/Atelier"
cp "$root"/App/Hammerspoon/Shell/*.swift "$root"/App/Hammerspoon/ShellCore/*.swift "$shell/Atelier/"
cp "$root"/App/Hammerspoon/IPC/*.swift "$shell/Modules/hs.ipc/"
cp "$root"/App/Hammerspoon/IPC/*.swift "$stage/source/hs2/"
[[ $(rg -l '^@main$' "$shell" -g '*.swift' | wc -l | tr -d ' ') == 1 ]] || { echo 'Expected exactly one app entry point' >&2; exit 1; }
mkdir -p "$stage/source/Hammerspoon 2.xcodeproj/xcshareddata/xcschemes"
cp "$root/App/Hammerspoon/Atelier.xcscheme" "$stage/source/Hammerspoon 2.xcodeproj/xcshareddata/xcschemes/"
# Xcode creates this empty directory while resolving the locked packages. Make
# it part of preparation so Xcode does not invalidate the source-tree receipt.
mkdir -p "$stage/source/Hammerspoon 2.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration"
[[ $("$root/scripts/native-inputs.sh" prepare) == "$inputs" ]] || { echo 'Preparation inputs changed during preparation; retry.' >&2; exit 1; }
rm -f "$receipt"
replace_directory "$stage/source" "$source_dir"
write_receipt "$source_dir" "$receipt" "$inputs"
printf 'Prepared HS2 %s\n' "$revision"
