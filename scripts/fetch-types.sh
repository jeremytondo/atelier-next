#!/usr/bin/env bash
# Put upstream's generated hammerspoon.d.ts for the pinned revision under
# .build/types, where tsconfig.json includes it. Nothing is rewritten while the
# revision recorded beside it matches the pin.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
revision=$(jq -er .revision "$root/hammerspoon2.json")
types="$root/.build/types"
if [[ -s $types/hammerspoon.d.ts && $(cat "$types/revision" 2>/dev/null) == "$revision" ]]; then
  exit 0
fi
archive=$("$root/scripts/hammerspoon-source.sh")
stage=$(mktemp -d "${TMPDIR:-/tmp}/atelier-types.XXXXXX")
trap 'rm -rf "$stage"' EXIT
member=$(tar -tzf "$archive" | grep -E '^[^/]+/docs/hammerspoon\.d\.ts$')
tar -xzf "$archive" -C "$stage" --strip-components=2 "$member"
[[ -s $stage/hammerspoon.d.ts ]] || die 'the pinned archive has no docs/hammerspoon.d.ts'
mkdir -p "$types"
mv "$stage/hammerspoon.d.ts" "$types/hammerspoon.d.ts"
printf '%s\n' "$revision" > "$types/revision"
echo "Type declarations: Hammerspoon 2 $revision"
