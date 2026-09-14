#!/usr/bin/env bash
# Credentials are preflighted before the full gate. Same-run verified native
# outputs are assembled once; status 78 means a dev plan became obsolete.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
plan=${1:?usage: ci-release.sh PLAN.json}; shift
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-release-run.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
export ATELIER_STALE_DEV_MARKER="$temporary/obsolete"
status=0
"$root/scripts/release-current.sh" "$plan" || status=$?
if [[ $status == 0 ]]; then
  "$root/scripts/ci-signing.sh" mise run release:verify-package "$plan" "$@" || status=$?
fi
if [[ -f $ATELIER_STALE_DEV_MARKER ]]; then
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then echo 'packaged=false' >> "$GITHUB_OUTPUT"; fi
  exit 0
fi
[[ $status == 0 ]] || exit "$status"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then echo 'packaged=true' >> "$GITHUB_OUTPUT"; fi
