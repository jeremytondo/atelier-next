#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# -eq 1 ]] || { echo 'usage: scripts/validate-release-plan.sh PLAN.json' >&2; exit 2; }
jq -e '
  (.channel == "dev" or .channel == "stable") and
  (.marketing_version | test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
  (.build_number | test("^[0-9]{14}$")) and
  (.commit | test("^[0-9a-f]{40}$")) and
  (.source_ref | startswith("refs/heads/")) and
  (.built_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.build_number == (.built_at | gsub("[-:TZ]"; ""))) and
  (.tag == ("v" + .version)) and
  (if .channel == "stable" then .version == .marketing_version
   else .version == (.marketing_version + "-dev." + .build_number) end)
' "$1" > /dev/null || die "Invalid release plan: $1"
git check-ref-format "$(jq -r .source_ref "$1")" || die "Invalid release source ref: $1"
