#!/usr/bin/env bash
# One build identity is created before packaging and carried through publication.
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
if [[ $channel == stable && $(repository_git rev-parse --is-shallow-repository) != false ]]; then
  die 'stable release planning requires full history and tags (fetch-depth: 0 in CI)'
fi
commit=$("$root/scripts/source-commit.sh")
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Keep the local alpha's timestamp convention. Seconds also distinguish rebuilds
# of the same commit and let a later stable build follow a calendar-versioned dev.
build_number=${built_at//[-:TZ]/}
if [[ $channel == stable ]]; then
  tag=$("$root/scripts/next-version.sh" "$2")
  version=${tag#v}
  marketing_version=$version
else
  tag=dev
  marketing_version="${built_at:0:4}.$((10#${built_at:5:2})).$((10#${built_at:8:2}))"
  version="$marketing_version-dev.t${build_number:8}+${commit:0:8}"
fi
arguments=()
for field in "${release_plan_fields[@]}"; do arguments+=(--arg "$field" "${!field}"); done
jq -n "${arguments[@]}" '$ARGS.named'
