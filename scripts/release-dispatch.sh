#!/usr/bin/env bash
# Release only an explicitly selected remote branch; local changes are never pushed.
set -euo pipefail
usage() { echo 'usage: mise run release:dev|patch|minor|major [BRANCH] (default: main)' >&2; exit 2; }
[[ $# -ge 1 && $# -le 2 ]] || usage
bump=$1
case "$bump" in dev|patch|minor|major) ;; *) usage ;; esac
branch=${2-main}
git check-ref-format "refs/heads/$branch" || usage
export GH_REPO=${GITHUB_REPOSITORY:-${GH_REPO:-jeremytondo/atelier-next}}
# A tag with the same spelling must never substitute for a missing branch.
encoded_branch=$(jq -rn --arg branch "$branch" '$branch | @uri')
gh api "repos/$GH_REPO/git/ref/heads/$encoded_branch" --silent
gh workflow run release.yml --ref "refs/heads/$branch" -f "bump=$bump"
