#!/usr/bin/env bash
# Reference source is local research material, never a build dependency.
# Fetch only creates missing checkouts. Updates preserve local work by requiring
# a clean upstream branch and refusing divergent history before merging.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
checkout="$root/repos/hammerspoon2"
upstream=https://github.com/cmsj/Hammerspoon2.git
mode=${1:-fetch}
[[ $# -le 1 ]] || die 'usage: mise run refs | refs:update | refs:status'
case "$mode" in fetch|update|status) ;; *) die 'expected fetch, update, or status' ;; esac

if [[ ! -e $checkout && ! -L $checkout ]]; then
  if [[ $mode == status ]]; then
    echo 'repos/hammerspoon2 is not installed; run mise run refs.'
    exit 0
  fi
  mkdir -p "$root/repos"
  git clone --depth 1 --single-branch --branch main --no-tags "$upstream" "$checkout"
  # A fresh clone already has the requested revision.
  mode=fetch
fi
[[ -d $checkout/.git && ! -L $checkout ]] || die "expected a standalone Git checkout at $checkout"
[[ $(git -C "$checkout" remote get-url origin) == "$upstream" ]] || die "unexpected origin for $checkout; expected $upstream"

if [[ $mode == update ]]; then
  [[ -z $(git -C "$checkout" status --porcelain --untracked-files=all) ]] || die 'repos/hammerspoon2 has local changes; preserve them before updating.'
  [[ $(git -C "$checkout" branch --show-current) == main ]] || die 'repos/hammerspoon2 must be on main to update.'
  # Reject local commits even when they would happen to fast-forward upstream.
  [[ $(git -C "$checkout" rev-parse HEAD) == "$(git -C "$checkout" rev-parse refs/remotes/origin/main)" ]] || die 'repos/hammerspoon2 has a locally changed revision; preserve it before updating.'
  # Leave the original shallow boundary in place and fetch new commits since it.
  git -C "$checkout" fetch --no-tags origin main
  git -C "$checkout" merge --ff-only refs/remotes/origin/main
elif [[ $mode == fetch ]]; then
  echo 'Reference checkout ready; use mise run refs:update to refresh it.'
fi
git -C "$checkout" log -1 --format='repos/hammerspoon2: %h (%cs) %s'
if [[ $mode == status ]]; then
  git -C "$checkout" status --short --branch
fi
