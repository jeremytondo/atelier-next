#!/usr/bin/env bash
# Summaries describe observed wall time; overlapping phases are never summed.
# Completed-run totals/transfer timings remain in the GitHub run/job records.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
mkdir -p "$root/.build/metrics"
case "${1:-}" in
  start) date +%s > "$root/.build/metrics/job-start" ;;
  tools)
    {
      printf 'Runner: %s %s %s\n' "${RUNNER_OS:-local}" "${RUNNER_ARCH:-$(uname -m)}" "${ImageVersion:-local}"
      mise --version
      mise ls --current
      if [[ $(uname -s) == Darwin ]]; then "$root/scripts/toolchain.sh"; fi
    } > "$root/.build/metrics/tools.txt" ;;
  summary)
    summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
    {
      printf '### Build measurements\n\n'
      if [[ -f $root/.build/metrics/job-start ]]; then
        printf 'Job elapsed through summary: %ss (excludes final cleanup).\n\n' "$(( $(date +%s) - $(cat "$root/.build/metrics/job-start") ))"
      fi
      # shellcheck disable=SC2016
      printf 'Selection: `%s`. Host cache: `%s`; helpers cache: `%s`.\n\n' "${CHECK_MODE:-full}" "${HOST_CACHE_HIT:-not used}" "${HELPERS_CACHE_HIT:-not used}"
      printf '| Phase | Wall seconds | Exit |\n| --- | ---: | ---: |\n'
      shopt -s nullglob
      timings=("$root"/.build/metrics/*/timing.json)
      if [[ ${#timings[@]} -gt 0 ]]; then
        jq -sr 'sort_by(.start)[] | "| \(.phase) | \(.seconds * 1000 | round / 1000) | \(.status) |"' "${timings[@]}"
      fi
      printf '\nPhases overlap; native-test includes compilation. Test-body and compiler timing summaries are retained in raw logs.\n\n'
      native_logs=("$root"/.build/metrics/native-test.*/swift_package_test_*.log)
      if [[ ${#native_logs[@]} -gt 0 ]]; then
        printf 'Native compiler/test-body diagnostics (separate from invocation time):\n\n```text\n'
        sed -nE '/^Build complete!|Executed [0-9]+ tests|Test run with .* passed after/p' "${native_logs[@]}"
        printf '```\n\n'
      fi
      # shellcheck disable=SC2016
      for archive in "$root"/.build/cache/*.tar.gz; do printf 'Cache payload `%s`: %s bytes.\n\n' "$(basename "$archive")" "$(wc -c < "$archive")"; done
      if [[ -f $root/.build/metrics/tools.txt ]]; then
        printf '<details><summary>Toolchain and runner</summary>\n\n```text\n'
        cat "$root/.build/metrics/tools.txt"
        printf '\n```\n</details>\n'
      fi
    } >> "$summary" ;;
  *) echo 'usage: ci-metrics.sh start|tools|summary' >&2; exit 2 ;;
esac
