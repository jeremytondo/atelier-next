#!/usr/bin/env bash
# Probe the actual bundled JS engine without loading user config or mutating macOS.
set -euo pipefail
[[ $# == 1 && -d $1 ]] || { echo 'usage: scripts/bundle-test.sh APP_PATH' >&2; exit 2; }
app=$(cd "$1" && pwd -P)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-bundle-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
ATELIER_CONFIG_DIR="$temporary" "$app/Contents/MacOS/Atelier" --version
ATELIER_CONFIG_DIR="$temporary" "$app/Contents/MacOS/Atelier" --self-test
ATELIER_CONFIG_DIR="$temporary" "$app/Contents/Helpers/atelier-config" --bootstrap "$temporary"
test -s "$temporary/init.js"
printf '// customized\n' > "$temporary/init.js"
ATELIER_CONFIG_DIR="$temporary" "$app/Contents/Helpers/atelier-config" --bootstrap "$temporary"
[[ $(cat "$temporary/init.js") == '// customized' ]]
echo 'Installed-bundle configuration preservation passed.'
