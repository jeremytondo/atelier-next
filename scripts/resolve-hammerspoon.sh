#!/usr/bin/env bash
# Resolve a distribution ZIP without publishing. A snapshot miss builds once;
# GitHub errors, drafts, or corrupt existing assets fail instead of rebuilding.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# == 1 ]] || die 'usage: resolve-hammerspoon.sh OUTPUT_DIRECTORY'
output=$1
mkdir -p "$output"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-hs2-resolve.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
pin="$root/hammerspoon2.json"
manifest="$temporary/manifest.json"
archive="$temporary/Hammerspoon.2.zip"
if [[ $(jq -r .release "$pin") != null ]]; then
  tag=$(jq -er .release.tag "$pin")
  [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid upstream release tag.'
  gh api "repos/cmsj/Hammerspoon2/commits/$tag" --jq .sha > "$temporary/revision"
  [[ $(cat "$temporary/revision") == "$(jq -r .revision "$pin")" ]] || die 'The upstream release tag does not match the pinned revision.'
  url="https://github.com/cmsj/Hammerspoon2/releases/download/$tag/Hammerspoon.2.zip"
  jq -n --slurpfile pin "$pin" --arg url "$url" --arg tag "$tag" \
    '{schema: 1, kind: "upstream", pin: $pin[0], tag: $tag, version: $tag, url: $url, sha256: $pin[0].release.sha256}' > "$manifest"
  "$root/scripts/validate-hammerspoon.sh" "$pin" "$manifest"
  curl --fail --silent --show-error --location --retry 3 "$url" -o "$archive"
else
  inputs=$("$root/scripts/hammerspoon-inputs.sh")
  tag="hs2-$inputs"
  gh api --paginate --slurp "repos/$repository/releases?per_page=100" > "$temporary/releases.json"
  jq --arg tag "$tag" '[.[][] | select(.tag_name == $tag)][0] // null' "$temporary/releases.json" > "$temporary/existing.json"
  if [[ $(jq -r .id "$temporary/existing.json") != null ]]; then
    jq -e '.draft == false' "$temporary/existing.json" > /dev/null || die "HS2 snapshot $tag is an incomplete draft; inspect it before retrying."
    gh release download "$tag" --repo "$repository" --dir "$temporary" --pattern manifest.json --pattern Hammerspoon.2.zip
    [[ $(jq -r .inputs "$manifest") == "$inputs" ]] || die 'Published HS2 snapshot has different build inputs.'
    echo "Reusing HS2 snapshot $tag."
  else
    "$root/scripts/build-hammerspoon.sh" --distribution
    [[ $("$root/scripts/hammerspoon-inputs.sh") == "$inputs" ]] || die 'HS2 build inputs changed during compilation.'
    ditto -c -k --keepParent "$root/.build/native/hs2/Hammerspoon 2.app" "$archive"
    sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
    jq -n --slurpfile pin "$pin" --arg inputs "$inputs" --arg tag "$tag" --arg sha256 "$sha256" \
      --arg url "https://github.com/$repository/releases/download/$tag/Hammerspoon.2.zip" \
      '{schema: 1, kind: "snapshot", pin: $pin[0], inputs: $inputs, tag: $tag,
        version: ($pin[0].build + "," + $inputs), url: $url, sha256: $sha256,
        architecture: "arm64", notarized: true}' > "$manifest"
  fi
fi
"$root/scripts/validate-hammerspoon.sh" "$pin" "$manifest" "$archive"
ditto -x -k "$archive" "$temporary/unpacked"
app="$temporary/unpacked/Hammerspoon 2.app"
[[ $(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist") == "$(jq -r .build "$pin")" ]] || die 'HS2 ZIP has the wrong app build number.'
codesign --verify --deep --strict "$app"
spctl --assess --type execute "$app"
cp "$archive" "$output/Hammerspoon.2.zip"
cp "$manifest" "$output/manifest.json"
