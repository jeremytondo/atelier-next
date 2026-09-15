#!/usr/bin/env bash
# Snapshot identity includes only HS2 build inputs. Atelier versions, defaults,
# providers, Node, runner image versions, and checkout paths do not affect it.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ ${ATELIER_SIGN_IDENTITY:-} =~ ^[0-9A-Fa-f]{40}$ ]] || die 'HS2 snapshots require the preflighted Developer ID certificate hash.'
developer_dir=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
{
  jq -Sc '{revision, sha256, build}' "$root/hammerspoon2.json"
  "$root/scripts/tree-digest.sh" "$root" scripts/build-hammerspoon.sh scripts/hammerspoon-source.sh \
    scripts/hammerspoon-inputs.sh scripts/notarize.sh scripts/hs2 .xcodebuildmcp/config.yaml
  printf 'arm64\n%s\n' "$ATELIER_SIGN_IDENTITY"
  plutil -convert json -o - "$developer_dir/../version.plist"
  plutil -convert json -o - "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist"
  xcodebuildmcp --version
} | shasum -a 256 | awk '{print $1}'
