#!/usr/bin/env bash
# Dev only: build stock Hammerspoon 2 from the pinned revision with no patches,
# stamp the pinned build number so the runtime check passes, sign it for local
# use, and optionally install it in /Applications. Releases never use this;
# the tap installs upstream's signed ZIP. Use it while the pin is ahead of the
# newest upstream release.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$root"
usage() { echo 'usage: mise run hs2:build [--install]' >&2; exit 2; }
install_app=false
case "${1:-}" in '') ;; --install) install_app=true ;; *) usage ;; esac
[[ $# -le 1 ]] || usage
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die 'Hammerspoon 2 is built for Apple silicon only.'
revision=$(jq -er .revision hammerspoon2.json)
build=$(jq -er .build hammerspoon2.json)
archive=$("$root/scripts/hammerspoon-source.sh")
source_dir="$root/.build/hammerspoon2"
if [[ $(cat "$source_dir/.revision" 2>/dev/null) != "$revision" ]]; then
  rm -rf "$source_dir"
  mkdir -p "$source_dir"
  tar -xzf "$archive" --strip-components=1 -C "$source_dir"
  printf '%s\n' "$revision" > "$source_dir/.revision"
fi
# Release defaults include Intel slices even with an arm64 destination.
xcodebuildmcp macos build --project-path "$source_dir/Hammerspoon 2.xcodeproj" \
  --scheme Release --configuration Release --arch arm64 \
  --derived-data-path "$root/.build/hs2-derived" \
  --extra-args ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "CURRENT_PROJECT_VERSION=$build" \
    -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution
app="$root/.build/hs2-derived/Build/Products/Release/Hammerspoon 2.app"
contents="$app/Contents"
[[ -x "$contents/MacOS/Hammerspoon 2" ]] || die 'the build produced no app'
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$contents/Info.plist") == "$build" ]] || die 'the built app does not carry the pinned build number'
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-hs2.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
security find-identity -v -p codesigning > "$temporary/identities"
identity=$(signing_identity 'Apple Development' "$temporary/identities")
identity=${identity:--}
# Sign nested bundles inside out, preserving HS2's automation service.
for directory in "$contents/Frameworks" "$contents/XPCServices"; do
  [[ -d $directory ]] || continue
  while IFS= read -r -d '' path; do
    if [[ $path == */HammerspoonOSAScriptHelper.xpc ]]; then
      codesign --force --sign "$identity" --options runtime --timestamp=none \
        --entitlements scripts/hs2/osascript-entitlements.plist "$path"
    else
      codesign --force --sign "$identity" --options runtime --timestamp=none \
        --preserve-metadata=identifier,entitlements "$path"
    fi
  done < <(find "$directory" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \) -print0)
done
[[ ! -x $contents/MacOS/hs2 ]] || codesign --force --sign "$identity" --options runtime --timestamp=none "$contents/MacOS/hs2"
entitlements=scripts/hs2/entitlements.plist
if [[ $identity == - ]]; then
  # An ad-hoc signature has no team for hardened library validation.
  entitlements="$temporary/entitlements.plist"
  cp scripts/hs2/entitlements.plist "$entitlements"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements"
fi
codesign --force --sign "$identity" --options runtime --timestamp=none --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
output="$root/.build/native/hs2"
rm -rf "$output"
mkdir -p "$output"
ditto "$app" "$output/Hammerspoon 2.app"
printf 'Built: %s (build %s, revision %s)\n' "$output/Hammerspoon 2.app" "$build" "${revision:0:8}"
if [[ $install_app == true ]]; then
  installed='/Applications/Hammerspoon 2.app'
  ! pgrep -x 'Hammerspoon 2' > /dev/null || die 'Quit Hammerspoon 2 before replacing it. The build is ready under .build/native/hs2.'
  if [[ -e $installed ]]; then
    mkdir -p dist
    backup=$(mktemp -d "$root/dist/Hammerspoon-2-previous.XXXXXX")
    ditto "$installed" "$backup/Hammerspoon 2.app"
    rm -rf "$installed"
    printf 'Previous app saved to %s\n' "$backup"
  fi
  ditto "$output/Hammerspoon 2.app" "$installed"
  printf 'Installed: %s. Start it with: open -a "Hammerspoon 2"\n' "$installed"
fi
