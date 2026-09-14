#!/usr/bin/env bash
# Non-colocated jj workspaces have no .git entry. CI uses its checked-out HEAD.
set -euo pipefail
if [[ -d .jj ]] && command -v jj > /dev/null; then
  jj log -r @ --no-graph -T commit_id
  printf '\n'
else
  git rev-parse HEAD
fi
