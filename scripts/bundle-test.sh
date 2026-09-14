#!/usr/bin/env bash
# Probe the actual bundled JS engine without loading user config or mutating macOS.
set -euo pipefail
[[ $# -ge 1 && $# -le 2 && -d $1 ]] || { echo 'usage: scripts/bundle-test.sh APP_PATH [--ad-hoc]' >&2; exit 2; }
probe_args=(--self-test)
if [[ $# == 2 ]]; then
  [[ $2 == --ad-hoc ]] || exit 2
  # Same-team XPC cannot authenticate an ad-hoc signature. Distribution callers
  # always use the complete probe; no production XPC requirements are changed.
  probe_args+=(--self-test-no-xpc)
  echo 'Ad-hoc runtime probe: AppleScript/XPC requires the signed distribution probe.'
fi
app=$(cd "$1" && pwd -P)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-bundle-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
ATELIER_CONFIG_DIR="$temporary" "$app/Contents/MacOS/Atelier" --version
ATELIER_CONFIG_DIR="$temporary" "$app/Contents/MacOS/Atelier" "${probe_args[@]}"
ATELIER_CONFIG_DIR="$temporary" "$app/Contents/Helpers/atelier-config" --bootstrap "$temporary"
test -s "$temporary/init.js"
printf '// customized\n' > "$temporary/init.js"
ATELIER_CONFIG_DIR="$temporary" "$app/Contents/Helpers/atelier-config" --bootstrap "$temporary"
[[ $(cat "$temporary/init.js") == '// customized' ]]
echo 'Installed-bundle configuration preservation passed.'
