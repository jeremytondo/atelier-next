#!/usr/bin/env bash
# Transfer only compact unsigned outputs, never DerivedData. Exact-key cache
# restores still go through the normal input/output checks before any reuse.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ ${1:-} == --locked ]]; then shift; locked=true; else locked=false; fi
operation=${1:-}; kind=${2:-}
[[ $kind == host || $kind == helpers ]] || exit 2
if [[ $locked == false ]]; then
  exec "$root/scripts/with-lock.sh" "$root/.build/locks/$kind" "$0" --locked "$@"
fi
# shellcheck source=scripts/build-state.sh
source "$root/scripts/build-state.sh"
mkdir -p "$root/.build/cache" "$root/.build/native"
archive="$root/.build/cache/$kind.tar.gz"
case "$operation" in
  pack)
    if [[ $kind == host ]]; then command=build-hammerspoon.sh; else command=build-helpers.sh; fi
    "$root/scripts/$command" --locked --verify
    COPYFILE_DISABLE=1 tar -czf "$archive.tmp" -C "$root/.build/native" "$kind" "$kind.json"
    mv "$archive.tmp" "$archive" ;;
  unpack)
    [[ -f $archive ]] || { echo "$kind cache miss; native task will build."; exit 0; }
    # Check archives are scoped by GitHub ref; privileged release jobs never
    # restore them. Incompatible/damaged transfers fall back to compilation.
    stage=$(mktemp -d "$root/.build/cache/unpack.XXXXXX")
    trap 'rm -rf "$stage"' EXIT
    # Reject paths outside this layer before extraction. Corrupt archives never
    # overwrite existing verified outputs or get installed directly.
    if ! tar -tzf "$archive" > "$stage/entries" ||
        ! awk -v kind="$kind" '$0 ~ /(^\/|(^|\/)\.\.($|\/))/ || !($0 == kind "/" || $0 == kind ".json" || index($0, kind "/") == 1) {bad=1} END {exit bad}' "$stage/entries" ||
        ! tar -xzf "$archive" -C "$stage" ||
        ! receipt_valid "$stage/$kind" "$stage/$kind.json" "$("$root/scripts/native-inputs.sh" "$kind")"; then
      echo "$kind cache invalid; native task will build or verify local output."
      exit 0
    fi
    replace_directory "$stage/$kind" "$root/.build/native/$kind"
    mv "$stage/$kind.json" "$root/.build/native/$kind.json" ;;
  *) exit 2 ;;
esac
if [[ -f $archive ]]; then printf '%s cache payload bytes: %s\n' "$kind" "$(wc -c < "$archive")"; fi
