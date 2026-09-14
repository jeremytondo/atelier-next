#!/usr/bin/env bash
# Assembly receives a private copy while both producers are locked. Neither
# signing nor resource overlays ever modify the verified unsigned outputs.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
case "${1:-}" in
  --host-locked)
    shift
    exec "$root/scripts/with-lock.sh" "$root/.build/locks/helpers" "$0" --locked "$@" ;;
  --locked) shift ;;
  *) exec "$root/scripts/with-lock.sh" "$root/.build/locks/host" "$0" --host-locked "$@" ;;
esac
[[ $# == 1 && -d $1 ]] || { echo 'usage: snapshot-native.sh EXISTING_PRIVATE_DIRECTORY' >&2; exit 2; }
"$root/scripts/build-hammerspoon.sh" --locked --verify
"$root/scripts/build-helpers.sh" --locked --verify
ditto "$root/.build/native/host" "$1/host"
ditto "$root/.build/native/helpers" "$1/helpers"
