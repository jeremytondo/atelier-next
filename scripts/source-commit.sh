#!/usr/bin/env bash
# The working-copy commit of the current directory: jj's @ or Git's HEAD.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if in_jj_workspace; then
  jj log -r @ --no-graph -T commit_id
  printf '\n'
else
  git rev-parse HEAD
fi
