#!/usr/bin/env bash
# Build the Atelier.app that ships: a Release build with the `atelier` command
# inside it, signed with Developer ID, notarized, stapled, and zipped into
# dist/. App, command, and dist/release.json must name the same build, or
# nothing is produced. Publishing is another step; this uploads nothing.
#
# usage: scripts/package.sh VERSION BUILD [--skip-notarization]
#   VERSION  such as 0.1.0
#   BUILD    digits only; a dev release advances it every time
#
# Notarization reads ATELIER_APP_STORE_CONNECT_KEY_PATH, _KEY_ID, and
# _ISSUER_ID, which scripts/with-signing.sh provides on a runner. An archive
# made with --skip-notarization is for looking at locally and must never be
# published; release.json says which kind it is.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
die() {
  echo "package.sh: $*" >&2
  exit 1
}

usage='usage: scripts/package.sh VERSION BUILD [--skip-notarization]'
# Exactly, so that a mistyped option is refused rather than ignored.
[[ $# -eq 2 || ($# -eq 3 && $3 == --skip-notarization) ]] || die "$usage"
version=$1
build=$2
notarize=true
[[ $# -eq 3 ]] && notarize=false
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "VERSION must be like 0.1.0, not $version"
[[ $build =~ ^[0-9]+$ ]] || die "BUILD must be digits, not $build"

identity=${ATELIER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
  sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}
[[ -n $identity ]] || die 'no Developer ID Application identity in the keychain'
if $notarize; then
  for name in ATELIER_APP_STORE_CONNECT_KEY_PATH ATELIER_APP_STORE_CONNECT_KEY_ID ATELIER_APP_STORE_CONNECT_ISSUER_ID; do
    [[ -n ${!name:-} ]] || die "notarization needs $name"
  done
fi

# The build's name is compiled into the app and the command from this file.
# It is put back afterwards, so packaging leaves the checkout as it was.
identity_file="$root/Sources/Client/Build.swift"
saved=$(mktemp "${TMPDIR:-/tmp}/atelier-build-swift.XXXXXX")
cp "$identity_file" "$saved"
trap 'cp "$saved" "$identity_file"; rm -f "$saved"' EXIT
sed -i '' -E \
  -e "s/(static let version = )\"[^\"]*\"/\1\"$version\"/" \
  -e "s/(static let number = )\"[^\"]*\"/\1\"$build\"/" "$identity_file"
grep -q "static let version = \"$version\"" "$identity_file" || die 'could not write the version into Build.swift'
grep -q "static let number = \"$build\"" "$identity_file" || die 'could not write the build into Build.swift'

dist="$root/dist"
stage="$dist/stage"
rm -rf "$dist"
mkdir -p "$stage"

# Signed below, once the command is inside, so the build itself signs ad hoc.
xcodebuildmcp macos build --project-path "$root/App/Atelier.xcodeproj" --scheme Atelier \
  --configuration Release --arch arm64 --derived-data-path "$root/.build/xcode-release" \
  --extra-args "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build" "CODE_SIGN_IDENTITY=-"
xcodebuildmcp swift-package build --package-path "$root" --configuration release --architectures arm64

app="$stage/Atelier.app"
ditto "$root/.build/xcode-release/Build/Products/Release/Atelier.app" "$app"
mkdir -p "$app/Contents/Helpers"
ditto "$root/.build/release/atelier" "$app/Contents/Helpers/atelier"

# Inside out: the command first, then the app that contains it.
codesign --force --options runtime --timestamp --identifier com.elevenideas.Atelier.cli \
  --sign "$identity" "$app/Contents/Helpers/atelier"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

# One build, named the same three ways.
plist="$app/Contents/Info.plist"
app_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist"))"
command_name=$("$app/Contents/Helpers/atelier" --version)
[[ $app_name == "$version ($build)" ]] || die "the app names itself $app_name, not $version ($build)"
[[ $command_name == "$version ($build)" ]] || die "the command names itself $command_name, not $version ($build)"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist") == com.elevenideas.Atelier ]] ||
  die 'the app does not have the released bundle identifier'

if $notarize; then
  credentials=(--key "$ATELIER_APP_STORE_CONNECT_KEY_PATH" --key-id "$ATELIER_APP_STORE_CONNECT_KEY_ID"
    --issuer "$ATELIER_APP_STORE_CONNECT_ISSUER_ID")
  ditto -c -k --keepParent "$app" "$dist/submission.zip"
  xcrun notarytool submit "$dist/submission.zip" "${credentials[@]}" --wait --timeout 20m \
    --output-format json >"$dist/notarization.json" || {
    cat "$dist/notarization.json" >&2
    die 'notarization failed or timed out'
  }
  grep -q '"status" *: *"Accepted"' "$dist/notarization.json" || {
    cat "$dist/notarization.json" >&2
    die 'notarization was not accepted'
  }
  rm "$dist/submission.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi

# Dev builds of one version differ only by build, so the archive is named by both.
asset="Atelier-$version-$build.zip"
ditto -c -k --keepParent "$app" "$dist/$asset"
sha256=$(shasum -a 256 "$dist/$asset" | cut -d ' ' -f 1)
cat >"$dist/release.json" <<JSON
{
  "version": "$version",
  "build": "$build",
  "asset": "$asset",
  "sha256": "$sha256",
  "notarized": $notarize
}
JSON
rm -rf "$stage"
echo "$dist/$asset"
