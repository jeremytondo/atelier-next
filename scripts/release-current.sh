#!/usr/bin/env bash
# Stale dev work stops before compilation/notarization. Publication keeps its
# own final check; stable plans always retain their selected-commit semantics.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
"$root/scripts/validate-release-plan.sh" "${1:?usage: release-current.sh PLAN.json}"
[[ $(jq -r .channel "$1") == dev ]] || exit 0
temporary=$(mktemp "${TMPDIR:-/tmp}/atelier-main.XXXXXX")
trap 'rm -f "$temporary"' EXIT
repository=${GITHUB_REPOSITORY:-${GH_REPO:-jeremytondo/atelier-next}}
gh api "repos/$repository/git/ref/heads/main" > "$temporary"
remote_main=$(jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' "$temporary")
commit=$(jq -r .commit "$1")
if [[ $remote_main != "$commit" ]]; then
  echo "Skipping obsolete dev build $commit; main is now $remote_main."
  if [[ -n ${ATELIER_STALE_DEV_MARKER:-} ]]; then touch "$ATELIER_STALE_DEV_MARKER"; fi
  exit 78
fi
