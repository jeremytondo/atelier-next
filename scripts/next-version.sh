#!/usr/bin/env bash
# Stable versions come from published SemVer tags, never from dev dates.
set -euo pipefail

[[ $# -eq 1 ]] || { echo 'usage: scripts/next-version.sh patch|minor|major' >&2; exit 2; }
case "$1" in patch|minor|major) ;; *) echo 'expected patch, minor, or major' >&2; exit 2 ;; esac

latest=$(git tag --list 'v*' --sort=-v:refname | awk '/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ && !found { print; found=1 }')
IFS=. read -r major minor patch <<< "${latest#v}"
major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}
case "$1" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac
printf 'v%s.%s.%s\n' "$major" "$minor" "$patch"
