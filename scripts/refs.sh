#!/usr/bin/env bash
# Research checkout follows the pin, never supplies build inputs. A private
# Git ref records the last managed commit so updates cannot discard local commits.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
checkout="$root/repos/hammerspoon2"
upstream=https://github.com/cmsj/Hammerspoon2.git
revision=$(jq -er .revision "$root/hammerspoon2.json")
[[ $revision =~ ^[0-9a-f]{40}$ ]] || die 'expected a 40-hex HS2 revision'
mode=${1:-fetch}
[[ $# -le 1 ]] || die 'usage: mise run refs | refs:update | refs:status'
case "$mode" in fetch|update|status) ;; *) die 'expected fetch, update, or status' ;; esac

if [[ ! -e $checkout && ! -L $checkout ]]; then
  if [[ $mode == status ]]; then
    echo "Reference checkout missing; expected $revision. Run mise run refs."
    exit 0
  fi
  mkdir -p "$checkout"
  git -C "$checkout" init -q
  git -C "$checkout" remote add origin "$upstream"
  mode=update
fi
[[ -d $checkout/.git && ! -L $checkout ]] || die 'expected a standalone reference checkout'
[[ $(git -C "$checkout" remote get-url origin) == "$upstream" ]] || die 'unexpected reference origin'

if [[ $mode == update ]]; then
  [[ -z $(git -C "$checkout" status --porcelain --untracked-files=all) ]] || die 'Reference checkout has local changes; preserve them before updating.'
  current=$(git -C "$checkout" rev-parse --verify HEAD 2>/dev/null || true)
  if [[ -n $current ]]; then
    managed=$(git -C "$checkout" rev-parse --verify refs/atelier/pin 2>/dev/null || true)
    if [[ -z $managed ]]; then
      # Migrate the old main-following checkout only at its last fetched main.
      [[ $(git -C "$checkout" branch --show-current) == main ]] || die 'Unmanaged reference checkout; preserve its revision before replacing it.'
      managed=$(git -C "$checkout" rev-parse --verify refs/remotes/origin/main)
    fi
    [[ $current == "$managed" ]] || die 'Reference checkout has a locally changed revision; preserve it before updating.'
  fi
  git -C "$checkout" fetch --depth 1 --no-tags origin "$revision"
  git -C "$checkout" switch --detach "$revision"
  git -C "$checkout" update-ref refs/atelier/pin "$revision"
fi
current=$(git -C "$checkout" rev-parse HEAD)
printf 'Reference: %s\nExpected:  %s\n' "$current" "$revision"
if [[ $current == "$revision" ]]; then
  echo 'Reference matches the pin.'
else
  echo 'Reference differs; run mise run refs:update.'
fi
git -C "$checkout" status --short
