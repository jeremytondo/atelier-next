#!/usr/bin/env bash
# Read completed run records so queue/workflow elapsed, summed job time, and
# cache/artifact transfer steps are distinguishable from nested build timings.
set -euo pipefail
[[ $# == 1 && $1 =~ ^[0-9]+$ ]] || { echo 'usage: mise run ci:report RUN_ID' >&2; exit 2; }
repository=${GITHUB_REPOSITORY:-${GH_REPO:-jeremytondo/atelier-next}}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-ci-report.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
gh api "repos/$repository/actions/runs/$1" > "$temporary/run.json"
gh api --paginate --slurp "repos/$repository/actions/runs/$1/jobs?per_page=100&filter=latest" > "$temporary/jobs.json"
jq -n --slurpfile run "$temporary/run.json" --slurpfile pages "$temporary/jobs.json" '
  def epoch: fromdateiso8601;
  def elapsed: (.completed_at | epoch) - (.started_at | epoch);
  $run[0] as $r | [$pages[0][].jobs[] | select(.started_at != null and .completed_at != null)] as $jobs |
  if $r.status != "completed" or ($jobs | length) == 0 then error("Run must be completed") else
    {url: $r.html_url, commit: $r.head_sha, attempt: $r.run_attempt, conclusion: $r.conclusion,
     elapsed_origin: (if $r.run_attempt > 1 then "attempt start (rerun queue excluded)" else "run creation" end),
     workflow_elapsed_seconds: (($jobs | map(.completed_at | epoch) | max) -
       ((if $r.run_attempt > 1 then $r.run_started_at else $r.created_at end) | epoch)),
     total_job_seconds: ($jobs | map(elapsed) | add),
     jobs: [$jobs[] | {name, conclusion, seconds: elapsed,
       steps: [.steps[] | select(.started_at != null and .completed_at != null) |
         {name, conclusion, seconds: elapsed}]}]}
  end'
