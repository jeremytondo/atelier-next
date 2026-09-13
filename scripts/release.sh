#!/usr/bin/env bash
# Dispatch remote main; never push or silently include local working-copy edits.
set -euo pipefail
usage() { echo 'usage: mise run release:dev | release:patch | release:minor | release:major' >&2; exit 2; }
[[ $# -eq 1 ]] || usage
bump=$1
case "$bump" in
  dev|patch|minor|major) ;;
  *) usage ;;
esac
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export GH_REPO=${GH_REPO:-jeremytondo/atelier-next}
gh auth status --hostname github.com

workflow=release.yml
request_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
title="Atelier Release [$bump:$request_id]"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-dispatch.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

gh workflow run "$workflow" --ref main -f "bump=$bump" -f "request_id=$request_id"
printf 'Dispatched %s release from remote main. Local changes are not included.\n' "$bump"
run_id=''
for ((attempt=0; attempt<30; attempt++)); do
  gh run list --workflow "$workflow" --event workflow_dispatch --branch main \
    --limit 100 --json databaseId,displayTitle > "$temporary/runs.json"
  run_id=$(jq -r --arg title "$title" '[.[] | select(.displayTitle == $title)][0].databaseId // empty' "$temporary/runs.json")
  [[ -z $run_id ]] || break
  sleep 2
done
[[ -n $run_id ]] || { echo "The run has not appeared yet; check gh run list --workflow $workflow" >&2; exit 1; }
gh run watch "$run_id" --exit-status
gh run view "$run_id" --json url --jq .url
