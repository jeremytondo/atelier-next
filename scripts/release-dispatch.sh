#!/usr/bin/env bash
# Start a release for one explicitly named remote branch. This never pushes
# local work, and spelling the ref as refs/heads/... prevents a tag with the
# same name from being accepted in its place.
#
# usage: scripts/release-dispatch.sh dev|patch|minor|major [BRANCH]
set -euo pipefail
die() {
  echo "release-dispatch.sh: $*" >&2
  exit 1
}
[[ $# -ge 1 && $# -le 2 ]] || die 'usage: scripts/release-dispatch.sh dev|patch|minor|major [BRANCH]'
bump=$1
case $bump in
  dev | patch | minor | major) ;;
  *) die "expected dev, patch, minor, or major, not $bump" ;;
esac
branch=${2:-main}
git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || die "not a branch name: $branch"
gh workflow run release.yml --repo jeremytondo/atelier-next --ref "refs/heads/$branch" -f "bump=$bump"
