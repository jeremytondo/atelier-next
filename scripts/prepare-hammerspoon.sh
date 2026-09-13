#!/usr/bin/env bash
# Recreate the product dependency from a verified upstream archive and tracked
# patches. The research checkout under repos/ never participates in builds.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
revision=$(jq -er .revision "$root/App/Hammerspoon/upstream.json")
checksum=$(jq -er .sha256 "$root/App/Hammerspoon/upstream.json")
[[ $revision =~ ^[0-9a-f]{40}$ && $checksum =~ ^[0-9a-f]{64}$ ]] || exit 1
mkdir -p "$root/.build/downloads"
archive="$root/.build/downloads/hs2-$revision.tar.gz"
if [[ ! -f $archive ]]; then
  temporary=$(mktemp "$root/.build/downloads/hs2.XXXXXX")
  trap 'rm -f "$temporary"' EXIT
  curl --fail --silent --show-error --location --retry 3 \
    "https://codeload.github.com/cmsj/Hammerspoon2/tar.gz/$revision" -o "$temporary"
  [[ $(shasum -a 256 "$temporary" | awk '{print $1}') == "$checksum" ]] || { echo 'HS2 archive checksum mismatch' >&2; exit 1; }
  mv "$temporary" "$archive"
fi
[[ $(shasum -a 256 "$archive" | awk '{print $1}') == "$checksum" ]] || { echo 'HS2 archive checksum mismatch' >&2; exit 1; }
source_dir="$root/.build/hammerspoon2"
rm -rf "$source_dir"
mkdir -p "$source_dir"
tar -xzf "$archive" --strip-components=1 -C "$source_dir"
for patch_file in "$root"/App/Hammerspoon/*.patch; do
  patch --batch --fuzz=0 -d "$source_dir" -p1 < "$patch_file"
done
cp "$root/App/Hammerspoon/AtelierHost.swift" "$source_dir/Hammerspoon 2/Lifecycle/"
mkdir -p "$source_dir/Hammerspoon 2.xcodeproj/xcshareddata/xcschemes"
cp "$root/App/Hammerspoon/Atelier.xcscheme" "$source_dir/Hammerspoon 2.xcodeproj/xcshareddata/xcschemes/"
printf 'Prepared HS2 %s\n' "$revision"
