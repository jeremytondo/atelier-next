#!/usr/bin/env bash
# Build the Debug Atelier.app into .build/xcode. macOS ties the Accessibility
# permission to the app's signature, so a development certificate is used when
# the keychain has one; an ad hoc build, as in CI, loses the permission on
# every rebuild.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
identity=$(security find-identity -v -p codesigning |
  sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)
xcodebuildmcp macos build --project-path "$root/App/Atelier.xcodeproj" --scheme Atelier \
  --configuration Debug --arch arm64 --derived-data-path "$root/.build/xcode" \
  --extra-args "CODE_SIGN_IDENTITY=${identity:--}"
