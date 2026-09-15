#!/usr/bin/env bash
# Stale dev work stops before compilation/notarization. Publication keeps its
# own final check; stable plans always retain their selected-commit semantics.
# shellcheck disable=SC2154  # release-plan fields are defined by load_release_plan
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_release_plan "${1:?usage: release-current.sh PLAN.json}"
[[ $channel == dev ]] || exit 0
temporary=$(mktemp "${TMPDIR:-/tmp}/atelier-release-ref.XXXXXX")
trap 'rm -f "$temporary"' EXIT
branch=${source_ref#refs/heads/}
encoded_branch=$(jq -rn --arg branch "$branch" '$branch | @uri')
gh api "repos/$repository/git/ref/heads/$encoded_branch" > "$temporary"
remote_commit=$(jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' "$temporary")
if [[ $remote_commit != "$commit" ]]; then
  echo "Skipping obsolete dev build $commit; $branch is now $remote_commit."
  if [[ -n ${ATELIER_STALE_DEV_MARKER:-} ]]; then touch "$ATELIER_STALE_DEV_MARKER"; fi
  exit 78
fi
