#!/usr/bin/env bash
# Small in-process phase timer for assembly/signing; timed.sh wraps commands
# whose failures must also be recorded. Callers provide their repository root.
root=${root:?caller must set the repository root}
phase_start() { phase_started=$(perl -MTime::HiRes=time -e 'printf "%.3f", time'); }
phase_end() {
  local end directory
  end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  mkdir -p "$root/.build/metrics"
  directory=$(mktemp -d "$root/.build/metrics/$1.XXXXXX")
  jq -n --arg phase "$1" --argjson start "$phase_started" --argjson end "$end" --argjson status "${2:-0}" \
    '{phase: $phase, start: $start, end: $end, seconds: ($end - $start), status: $status}' > "$directory/timing.json"
}
