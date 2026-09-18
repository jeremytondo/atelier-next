#!/usr/bin/env bash
# Decide what a release is called, printing version, build, channel, and tag
# as name=value lines. Stable versions come from the vX.Y.Z tags; a dev build
# is the next patch version, told apart from the last dev build by its build,
# which is the UTC time and so always advances.
#
# usage: scripts/release-plan.sh dev|patch|minor|major
set -euo pipefail
die() {
  echo "release-plan.sh: $*" >&2
  exit 1
}
[[ $# -eq 1 ]] || die 'usage: scripts/release-plan.sh dev|patch|minor|major'
bump=$1
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

# A lookup that fails must stop the plan, which would otherwise start again
# from 0.0.1; finding no stable tag among those listed is not a failure.
tags=$(git -C "$root" tag --list 'v*') || die 'could not list the tags'
latest=$(grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' <<<"$tags" | sort -V | tail -n 1 || true)
IFS=. read -r major minor patch <<<"${latest#v}"
major=${major:-0} minor=${minor:-0} patch=${patch:-0}
case $bump in
  dev | patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)) patch=0 ;;
  major) major=$((major + 1)) minor=0 patch=0 ;;
  *) die "expected dev, patch, minor, or major, not $bump" ;;
esac
version="$major.$minor.$patch"
if [[ $bump == dev ]]; then
  channel=dev tag=dev
else
  # Next after the greatest tag listed above, so never one of them; the
  # publisher refuses a stable release that exists already.
  channel=stable tag="v$version"
fi
printf 'version=%s\nbuild=%s\nchannel=%s\ntag=%s\n' "$version" "$(date -u +%Y%m%d%H%M%S)" "$channel" "$tag"
