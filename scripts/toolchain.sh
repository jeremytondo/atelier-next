#!/usr/bin/env bash
# Emit the actual native compiler/SDK identity, not a moving runner image label.
set -euo pipefail
developer_dir=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
printf 'OS: '; sw_vers -productVersion
printf 'OS build: '; sw_vers -buildVersion
printf 'Architecture: '; uname -m
plutil -convert json -o - "$developer_dir/../version.plist"
plutil -convert json -o - "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist"
"$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" --version 2>&1
"$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" --version
printf 'XcodeBuildMCP: '; xcodebuildmcp --version
printf 'Node: '; node --version
printf 'Overrides: %s\n' "${TOOLCHAINS:-}|${SDKROOT:-}|${SWIFT_EXEC:-}|${CC:-}|${CXX:-}"
