#!/usr/bin/env bash
# Keep the original HS2 target and dependency lockfile; Xcode builds its complete
# bundle so its resources, frameworks, and XPC service remain intact.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
"$root/scripts/prepare-hammerspoon.sh"
xcodebuildmcp macos build --project-path "$root/.build/hammerspoon2/Hammerspoon 2.xcodeproj" \
  --scheme Atelier --configuration Release --arch arm64 \
  --derived-data-path "$root/.build/hs2-derived" \
  --extra-args CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution
test -x "$root/.build/hs2-derived/Build/Products/Release/Hammerspoon 2.app/Contents/MacOS/Hammerspoon 2"
