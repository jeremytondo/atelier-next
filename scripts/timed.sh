#!/usr/bin/env bash
# One timing/log file per invocation avoids concurrent writers. Command status
# is preserved; raw MCP log paths are copied only from this command output.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
label=${1:?usage: timed.sh LABEL COMMAND...}; shift
[[ $label =~ ^[a-zA-Z0-9_-]+$ && $# -gt 0 ]] || exit 2
mkdir -p "$root/.build/metrics"
directory=$(mktemp -d "$root/.build/metrics/$label.XXXXXX")
start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
status=0
"$@" 2>&1 | tee "$directory/output.log" || status=$?
end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
jq -n --arg phase "$label" --argjson start "$start" --argjson end "$end" --argjson status "$status" \
  '{phase: $phase, start: $start, end: $end, seconds: ($end - $start), status: $status}' > "$directory/timing.json"
while IFS= read -r path; do
  if [[ $path == \~/* ]]; then path="$HOME/${path:2}"; fi
  [[ $path == "$HOME/Library/Developer/XcodeBuildMCP/workspaces/"*/logs/*.log ]] || continue
  [[ -f $path ]] || continue
  cp "$path" "$directory/$(basename "$path")"
done < <(sed -nE 's@.*Build Logs: (.*\.log).*@\1@p' "$directory/output.log")
exit "$status"
