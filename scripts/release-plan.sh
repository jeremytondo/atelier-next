#!/usr/bin/env bash
# One build identity is created before packaging and carried through publication.
# Dev versions are the next patch version with a `-dev.<build>` suffix, so each
# dev release has its own tag and the atelier@dev cask can point at it.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ATELIER_RELEASE_REPO_ROOT:-$root}"

usage() { echo 'usage: mise run release:plan dev [BRANCH] | stable patch|minor|major [BRANCH]' >&2; exit 2; }
channel=${1:-}
source_ref=${GITHUB_REF:-refs/heads/main}
case "$channel" in
  dev)
    [[ $# -ge 1 && $# -le 2 ]] || usage
    if [[ $# -eq 2 ]]; then source_ref="refs/heads/$2"; fi ;;
  stable)
    [[ $# -ge 2 && $# -le 3 ]] || usage
    if [[ $# -eq 3 ]]; then source_ref="refs/heads/$3"; fi ;;
  *) usage ;;
esac
if [[ $source_ref != refs/heads/* ]] || ! git check-ref-format "$source_ref"; then
  die 'release planning requires a branch ref'
fi
if [[ $(repository_git rev-parse --is-shallow-repository) != false ]]; then
  die 'release planning requires full history and tags (fetch-depth: 0 in CI)'
fi
# shellcheck disable=SC2034  # every plan field is read through ${!field}
commit=$("$root/scripts/source-commit.sh")
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Seconds distinguish rebuilds of the same commit and order dev releases.
build_number=${built_at//[-:TZ]/}
if [[ $channel == stable ]]; then
  tag=$("$root/scripts/next-version.sh" "$2")
  version=${tag#v}
  marketing_version=$version
else
  marketing_version=$("$root/scripts/next-version.sh" patch)
  marketing_version=${marketing_version#v}
  version="$marketing_version-dev.$build_number"
  tag="v$version"
fi
arguments=()
for field in "${release_plan_fields[@]}"; do arguments+=(--arg "$field" "${!field}"); done
jq -n "${arguments[@]}" '$ARGS.named'
