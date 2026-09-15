#!/usr/bin/env bash
# Definitions shared by the scripts in this directory. Source it after
# `set -euo pipefail`. It defines `root` (this checkout) and `repository` (the
# GitHub slug) and declares functions; it runs no commands and changes no
# directory. Git helpers act on the current directory's repository.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck disable=SC2034  # read by sourcing scripts
repository=${GITHUB_REPOSITORY:-${GH_REPO:-jeremytondo/atelier-next}}

die() { echo "error: $*" >&2; exit 1; }
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() { if "$@" > /dev/null 2>&1; then fail "unexpected success: $*"; fi; }

# Non-colocated jj workspaces have no .git entry; Git must read jj's store.
in_jj_workspace() { [[ -d .jj ]] && command -v jj > /dev/null; }
repository_git() {
  if in_jj_workspace; then git --git-dir "$(jj git root)" "$@"; else git "$@"; fi
}

# Hash of the first valid identity of KIND ("Developer ID Application" or
# "Apple Development") in a saved `security find-identity -v` listing.
signing_identity() { awk -v kind="\"$1:" 'index($0, kind) && !found {print $2; found=1}' "$2"; }

# Release plans and manifests carry these fields. load_release_plan validates
# a file and defines one shell variable per field.
release_plan_fields=(channel tag version marketing_version build_number commit built_at source_ref)
load_release_plan() {
  "$root/scripts/validate-release-plan.sh" "$1"
  local field
  for field in "${release_plan_fields[@]}"; do
    printf -v "$field" '%s' "$(jq -r --arg field "$field" '.[$field]' "$1")"
  done
}
