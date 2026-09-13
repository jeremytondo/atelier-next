#!/usr/bin/env bash
# Build a standalone app. Distribution is fail-closed: Developer ID, a secure
# timestamp, notarization, stapling, and Gatekeeper verification must all pass.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

usage() {
  cat <<'USAGE'
usage: mise run build [--install] [--launch] [--skip-build]
                      [--identity NAME_OR_HASH] [--build-number NUMBER]
                      [--output-dir DIR]
       mise run release:package PLAN.json [--skip-build] [--output-dir DIR]

Local builds default to Apple Development signing, then ad-hoc.
Release plans require Developer ID signing and notarization credentials.
USAGE
}
die() { echo "error: $*" >&2; exit 1; }
install_app=false; launch=false; skip_build=false
identity=${ATELIER_SIGN_IDENTITY:-}
build_number=''; plan=''; output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) install_app=true; shift ;;
    --launch) launch=true; shift ;;
    --skip-build) skip_build=true; shift ;;
    --identity|--build-number|--release-plan|--output-dir)
      [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "missing value for $1"
      case "$1" in
        --identity) identity=$2 ;;
        --build-number) build_number=$2 ;;
        --release-plan) plan=$2 ;;
        --output-dir) output=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die 'Atelier currently targets Apple silicon Macs.'

channel=local
marketing_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Resources/Info.plist)
version="$marketing_version-local"
commit=$(git rev-parse HEAD)
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -n $plan ]]; then
  [[ -z $build_number ]] || die '--build-number cannot override a release plan'
  "$root/scripts/validate-release-plan.sh" "$plan"
  channel=$(jq -r .channel "$plan")
  version=$(jq -r .version "$plan")
  marketing_version=$(jq -r .marketing_version "$plan")
  build_number=$(jq -r .build_number "$plan")
  built_at=$(jq -r .built_at "$plan")
  [[ $(jq -r .commit "$plan") == "$commit" ]] || die 'release plan does not match this checkout'
fi
build_number=${build_number:-${built_at//[-:TZ]/}}
[[ $build_number =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die 'build number must contain one to three numeric components'
output=${output:-$root/dist}
mkdir -p "$output"
output=$(cd "$output" && pwd -P)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-package.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

signing_keychain=()
if [[ -n ${ATELIER_SIGN_KEYCHAIN:-} ]]; then signing_keychain=("$ATELIER_SIGN_KEYCHAIN"); fi
security find-identity -v -p codesigning ${signing_keychain[@]+"${signing_keychain[@]}"} > "$temporary/identities"
if [[ $channel == local ]]; then
  if [[ -z $identity ]]; then
    identity=$(awk '/"Apple Development:/ && !found {print $2; found=1}' "$temporary/identities")
    identity=${identity:--}
  fi
  timestamp=--timestamp=none
else
  if [[ -z $identity ]]; then
    identity=$(awk '/"Developer ID Application:/ && !found {print $2; found=1}' "$temporary/identities")
  fi
  [[ -n $identity && $identity != - ]] || die 'No Developer ID Application signing identity is available.'
  awk -v identity="$identity" '
    /"Developer ID Application:/ { name=$0; sub(/^[^"]*"/, "", name); sub(/".*$/, "", name);
      if ($2 == identity || name == identity) found=1 }
    END { exit !found }
  ' "$temporary/identities" || die 'Distribution requires a valid Developer ID Application identity.'
  timestamp=--timestamp
  # XcodeBuildMCP handles builds/tests. Notarization has no MCP command;
  # invoke the notary tools from the selected Xcode directly.
  developer_dir=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
  notarytool="$developer_dir/usr/bin/notarytool"
  stapler="$developer_dir/usr/bin/stapler"
  [[ -x $notarytool && -x $stapler ]] || die 'Select a full Xcode installation for notarization.'
  notary_args=()
  if [[ -n ${ATELIER_NOTARY_PROFILE:-} ]]; then
    notary_args=(--keychain-profile "$ATELIER_NOTARY_PROFILE")
  else
    for name in ATELIER_APP_STORE_CONNECT_KEY_PATH ATELIER_APP_STORE_CONNECT_KEY_ID ATELIER_APP_STORE_CONNECT_ISSUER_ID; do
      [[ -n ${!name:-} ]] || die "missing notarization credential: $name"
    done
    [[ -f $ATELIER_APP_STORE_CONNECT_KEY_PATH ]] || die 'App Store Connect API key file does not exist.'
    notary_args=(--key "$ATELIER_APP_STORE_CONNECT_KEY_PATH" --key-id "$ATELIER_APP_STORE_CONNECT_KEY_ID" --issuer "$ATELIER_APP_STORE_CONNECT_ISSUER_ID")
  fi
fi

if [[ $skip_build == false ]]; then
  xcodebuildmcp swift-package build --package-path "$root/App" --configuration release --architectures arm64
fi
binaries="$root/App/.build/release"
for executable in Atelier atelier-engine atelier-tools; do
  [[ -x $binaries/$executable ]] || die "missing release executable: $executable"
  [[ $(lipo -archs "$binaries/$executable") == arm64 ]] || die "expected an arm64 executable: $executable"
done
app="$temporary/Atelier.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources"
ditto "$binaries/Atelier" "$contents/MacOS/Atelier"
ditto "$binaries/atelier-engine" "$contents/Helpers/atelier-engine"
cp App/Resources/Configuration.md App/Resources/ThirdPartyNotices.txt "$contents/Resources/"
"$binaries/atelier-tools" --icon "$temporary/AppIcon.iconset"
iconutil -c icns "$temporary/AppIcon.iconset" -o "$contents/Resources/AppIcon.icns"
cp App/Resources/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$contents/Info.plist"
plutil -insert AtelierBuildVersion -string "$version" "$contents/Info.plist"
plutil -insert AtelierBuildChannel -string "$channel" "$contents/Info.plist"
plutil -insert AtelierBuildCommit -string "$commit" "$contents/Info.plist"
plutil -insert AtelierBuildDate -string "$built_at" "$contents/Info.plist"
# Credential setup uses umask 077; distributed bundles still need normal
# readable resources and traversable directories for other users on the Mac.
umask 022
chmod -R u=rwX,go=rX "$app"
for path in "$contents/Helpers/atelier-engine" "$app"; do
  codesign --force --sign "$identity" --options runtime "$timestamp" "$path"
done
codesign --verify --deep --strict --verbose=2 "$app"

if [[ $channel != local ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary/notarization.zip"
  mkdir -p "$output/notarization"
  if ! "$notarytool" submit "$temporary/notarization.zip" "${notary_args[@]}" \
      --wait --timeout 20m --output-format json > "$output/notarization/submission.json"; then
    cat "$output/notarization/submission.json" >&2
    die 'Notarization failed or timed out; no release package was produced.'
  fi
  if [[ $(jq -r .status "$output/notarization/submission.json") != Accepted ]]; then
    submission_id=$(jq -er .id "$output/notarization/submission.json")
    "$notarytool" log "$submission_id" "${notary_args[@]}" "$output/notarization/log.json"
    die "Notarization was rejected; see $output/notarization/log.json"
  fi
  "$stapler" staple "$app"
  "$stapler" validate "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  spctl --assess --type execute --verbose=2 "$app"
  archive_name=Atelier-macos-arm64.zip
else
  archive_name="Atelier-$marketing_version-$build_number-local.zip"
fi
# Nothing replaces the last package until signing and notarization have passed.
ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary/$archive_name"
rm -rf "$output/Atelier.app"
mv "$app" "$output/Atelier.app"
mv "$temporary/$archive_name" "$output/$archive_name"
if [[ $channel != local ]]; then
  jq '. + {architecture: "arm64", minimum_macos: "26.0", signing: "developer-id", notarized: true,
    asset: "Atelier-macos-arm64.zip"}' "$plan" > "$output/manifest.json"
  (cd "$output" && shasum -a 256 Atelier-macos-arm64.zip manifest.json > checksums.txt)
fi

launch_path="$output/Atelier.app"
if [[ $install_app == true ]]; then
  installed=/Applications/Atelier.app
  if pgrep -f '^/Applications/Atelier.app/Contents/MacOS/Atelier($| )' > /dev/null; then
    die 'Quit Atelier before replacing it. The new package is ready in dist/.'
  fi
  if [[ -e $installed ]]; then
    backup=$(mktemp -d "$output/Atelier-previous.XXXXXX")
    ditto "$installed" "$backup/Atelier.app"
    rm -rf "$installed"
  fi
  ditto "$output/Atelier.app" "$installed"
  launch_path=$installed
fi
printf 'App: %s\nZIP: %s\nVersion: %s (build %s, %s)\n' "$launch_path" "$output/$archive_name" "$version" "$build_number" "$channel"
if [[ $launch == true ]]; then
  xcodebuildmcp macos launch --app-path "$launch_path"
fi
