#!/usr/bin/env bash
# The named final check fails for failed/cancelled required jobs and unexpected
# skips. Workflow-level path filters must never suppress this result.
set -euo pipefail
[[ $# == 3 ]] || exit 2
[[ $1 == success ]] || { echo "Portable checks: $1" >&2; exit 1; }
case "$2:$3" in
  true:success|false:skipped) echo 'All selected checks passed.' ;;
  *) echo "Required native checks: $2; result: $3" >&2; exit 1 ;;
esac
