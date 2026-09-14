#!/usr/bin/env bash
# Unknown, deleted, renamed, or unavailable inputs select full validation.
# Only explicitly documented/research paths can omit bundle validation.
set -euo pipefail
temporary=$(mktemp "${TMPDIR:-/tmp}/atelier-diff.XXXXXX")
trap 'rm -f "$temporary"' EXIT
mode=docs
if [[ ${1:-} == --diff && $# == 2 ]]; then
  cp "$2" "$temporary"
elif [[ $# == 2 && $1 =~ ^[0-9a-f]{40}$ && $2 =~ ^[0-9a-f]{40}$ ]] &&
    git diff --name-status -z --no-renames "$1" "$2" > "$temporary"; then
  :
else
  mode=full
fi
seen=false
while IFS= read -r -d '' status || [[ -n $status ]]; do
  seen=true
  if ! IFS= read -r -d '' path; then mode=full; break; fi
  [[ $status == A || $status == M ]] || { mode=full; break; }
  case "$path" in
    README.md|AGENTS.md|docs/*|Prototypes/*|App/README.md|App/Hammerspoon/README.md|App/Evidence/*) ;;
    App/Resources/*|App/Tests/JavaScript/*) [[ $mode != docs ]] || mode=js ;;
    App/Sources/*|App/Tests/*|App/Package.swift|App/Package.resolved) mode=full ;;
    *) mode=full ;;
  esac
done < "$temporary"
[[ $seen == true ]] || mode=full
printf 'mode=%s\n' "$mode"
if [[ $mode == docs ]]; then printf 'native=false\n'; else printf 'native=true\n'; fi
