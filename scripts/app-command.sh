#!/usr/bin/env bash
# Diagnostic transport for an app explicitly launched with --diagnostic-control.
set -euo pipefail
[[ $# -eq 1 ]] || { echo 'usage: mise run app:command '\''{"command":"status"}'\''' >&2; exit 2; }
directory="$HOME/Library/Application Support/Atelier/diagnostic-control"
[[ -d $directory ]] || { echo 'Launch Atelier with --diagnostic-control first.' >&2; exit 1; }
umask 077
request_id=$(uuidgen)
temporary=$(mktemp "$directory/request.XXXXXX")
trap 'rm -f "$temporary"' EXIT
jq -e --arg id "$request_id" 'if type == "object" then . + {id: $id} else error("expected a JSON object") end' <<< "$1" > "$temporary"
mv "$temporary" "$directory/request.json"
for ((attempt=0; attempt<220; attempt++)); do
  if jq -e --arg id "$request_id" 'select(.id == $id)' "$directory/response.json" > "$temporary" 2>/dev/null; then
    cat "$temporary"
    jq -e '.ok == true' "$temporary" > /dev/null
    exit
  fi
  sleep 0.1
done
echo 'No response. Is Atelier running with --diagnostic-control? A timeout is not proof a mutation did not happen.' >&2
exit 1
