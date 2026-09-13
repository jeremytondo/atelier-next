#!/usr/bin/env bash
# One build identity is created before packaging and carried through publication.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cd "${ATELIER_RELEASE_REPO_ROOT:-$script_dir/..}"

usage() { echo 'usage: mise run release:plan dev | stable patch|minor|major' >&2; exit 2; }
channel=${1:-}
case "$channel" in
  dev) [[ $# -eq 1 ]] || usage ;;
  stable) [[ $# -eq 2 ]] || usage ;;
  *) usage ;;
esac
[[ $(git rev-parse --is-shallow-repository) == false ]] || {
  echo 'release planning requires full history and tags (fetch-depth: 0 in CI)' >&2; exit 1;
}
commit=$(git rev-parse HEAD)
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Keep the local alpha's timestamp convention. Seconds also distinguish rebuilds
# of the same commit and let a later stable build follow a calendar-versioned dev.
build_number=${built_at//[-:TZ]/}
if [[ $channel == stable ]]; then
  tag=$("$script_dir/next-version.sh" "$2")
  version=${tag#v}
  marketing_version=$version
else
  tag=dev
  marketing_version="${built_at:0:4}.$((10#${built_at:5:2})).$((10#${built_at:8:2}))"
  version="$marketing_version-dev.t${build_number:8}+${commit:0:8}"
fi
jq -n --arg channel "$channel" --arg tag "$tag" --arg version "$version" \
  --arg marketing_version "$marketing_version" --arg build_number "$build_number" \
  --arg commit "$commit" --arg built_at "$built_at" \
  '{channel: $channel, tag: $tag, version: $version, marketing_version: $marketing_version,
    build_number: $build_number, commit: $commit, built_at: $built_at}'
