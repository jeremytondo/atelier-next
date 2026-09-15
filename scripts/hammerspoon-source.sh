#!/usr/bin/env bash
# The pinned Hammerspoon 2 source archive, downloaded once and verified on every
# use; prints its path. The type declarations and the dev-only HS2 build read
# it. Releases never do: they reference upstream's signed release ZIP.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
revision=$(jq -er .revision "$root/hammerspoon2.json")
checksum=$(jq -er .sha256 "$root/hammerspoon2.json")
[[ $revision =~ ^[0-9a-f]{40}$ && $checksum =~ ^[0-9a-f]{64}$ ]] || die 'hammerspoon2.json needs a 40-hex revision and a 64-hex sha256'
mkdir -p "$root/.build/downloads"
archive="$root/.build/downloads/hs2-$revision.tar.gz"
verify() { [[ $(shasum -a 256 "$1" | awk '{print $1}') == "$checksum" ]]; }
if [[ ! -f $archive ]]; then
  temporary=$(mktemp "$root/.build/downloads/hs2-download.XXXXXX")
  trap 'rm -f "$temporary"' EXIT
  curl --fail --silent --show-error --location --retry 3 \
    "https://codeload.github.com/cmsj/Hammerspoon2/tar.gz/$revision" -o "$temporary"
  verify "$temporary" || die 'Hammerspoon 2 archive checksum mismatch'
  mv "$temporary" "$archive"
fi
verify "$archive" || die "Hammerspoon 2 archive checksum mismatch; delete $archive and retry"
echo "$archive"
