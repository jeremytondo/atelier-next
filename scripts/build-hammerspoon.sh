#!/usr/bin/env bash
# Build unpatched HS2 at the pin. Local builds can install into /Applications;
# distribution builds use Developer ID and notarization and never install.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$root"
usage() { echo 'usage: mise run hs2:build [--install | --distribution]' >&2; exit 2; }
install_app=false
distribution=false
case "${1:-}" in '') ;; --install) install_app=true ;; --distribution) distribution=true ;; *) usage ;; esac
[[ $# -le 1 ]] || usage
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die 'Hammerspoon 2 is built for Apple silicon only.'
revision=$(jq -er .revision hammerspoon2.json)
build=$(jq -er .build hammerspoon2.json)
[[ $build =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die 'Invalid HS2 build number.'
# Reject compiler overrides that would invalidate the recorded build inputs.
for override in TOOLCHAINS SDKROOT SWIFT_EXEC CC CXX XCODE_XCCONFIG_FILE; do
  [[ -z ${!override:-} ]] || die "Unsupported build override: $override"
done
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-hs2.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
signing_keychain=()
if [[ -n ${ATELIER_SIGN_KEYCHAIN:-} ]]; then signing_keychain=("$ATELIER_SIGN_KEYCHAIN"); fi
security find-identity -v -p codesigning ${signing_keychain[@]+"${signing_keychain[@]}"} > "$temporary/identities"
timestamp=--timestamp=none
if [[ $distribution == true ]]; then
  identity=${ATELIER_SIGN_IDENTITY:-$(signing_identity 'Developer ID Application' "$temporary/identities")}
  [[ -n $identity && $identity != - ]] || die 'HS2 distribution requires Developer ID signing.'
  awk -v identity="$identity" '$2 == identity && /"Developer ID Application:/ { found=1 } END { exit !found }' \
    "$temporary/identities" || die 'HS2 distribution requires a valid Developer ID certificate hash.'
  timestamp=--timestamp
else
  identity=$(signing_identity 'Apple Development' "$temporary/identities")
  identity=${identity:--}
fi
archive=$("$root/scripts/hammerspoon-source.sh")
source_dir="$root/.build/hammerspoon2"
# Always reconstruct from the verified archive: scratch-source edits must not
# become a published snapshot with the identity of unmodified upstream source.
rm -rf "$source_dir"
mkdir -p "$source_dir"
tar -xzf "$archive" --strip-components=1 -C "$source_dir"
# Release defaults include Intel slices even with an arm64 destination.
xcodebuildmcp macos build --project-path "$source_dir/Hammerspoon 2.xcodeproj" \
  --scheme Release --configuration Release --arch arm64 \
  --derived-data-path "$root/.build/hs2-derived" \
  --extra-args ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "CURRENT_PROJECT_VERSION=$build" \
    -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution
app="$root/.build/hs2-derived/Build/Products/Release/Hammerspoon 2.app"
contents="$app/Contents"
[[ -x "$contents/MacOS/Hammerspoon 2" ]] || die 'the build produced no app'
cp "$source_dir/LICENSE" "$contents/Resources/Hammerspoon2-LICENSE"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$contents/Info.plist") == "$build" ]] || die 'the built app does not carry the pinned build number'
# Sign nested bundles inside out, preserving HS2's automation service.
for directory in "$contents/Frameworks" "$contents/XPCServices"; do
  [[ -d $directory ]] || continue
  while IFS= read -r -d '' path; do
    if [[ $path == */HammerspoonOSAScriptHelper.xpc ]]; then
      codesign --force --sign "$identity" --options runtime "$timestamp" \
        --entitlements scripts/hs2/osascript-entitlements.plist "$path"
    else
      codesign --force --sign "$identity" --options runtime "$timestamp" \
        --preserve-metadata=identifier,entitlements "$path"
    fi
  done < <(find "$directory" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \) -print0)
done
[[ ! -x $contents/MacOS/hs2 ]] || codesign --force --sign "$identity" --options runtime "$timestamp" "$contents/MacOS/hs2"
entitlements=scripts/hs2/entitlements.plist
if [[ $identity == - ]]; then
  # An ad-hoc signature has no team for hardened library validation.
  entitlements="$temporary/entitlements.plist"
  cp scripts/hs2/entitlements.plist "$entitlements"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements"
fi
codesign --force --sign "$identity" --options runtime "$timestamp" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
if [[ $distribution == true ]]; then
  "$root/scripts/notarize.sh" "$app" "${ATELIER_NOTARIZATION_DIR:-$root/.build/notarization}/hammerspoon2"
fi
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
