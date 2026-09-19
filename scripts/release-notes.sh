#!/usr/bin/env bash
# Write release notes for the PRs included in HEAD but not BASE. A full local
# history is required. Match GitHub's merged PRs to commits, so branch builds
# exclude unrelated merges and merge, squash, and rebase all work alike.
# With no BASE, include every merged PR in HEAD's history.
#
# usage: scripts/release-notes.sh dev|stable HEAD [BASE]
set -euo pipefail
[[ $# -ge 2 && $# -le 3 ]] || { echo 'usage: scripts/release-notes.sh dev|stable HEAD [BASE]' >&2; exit 1; }
channel=$1 head=$2 base=${3:-}
repository=jeremytondo/atelier-next
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
case $channel in
  dev) token=atelier@dev ;;
  stable) token=atelier ;;
  *) echo "release-notes.sh: unknown channel: $channel" >&2; exit 1 ;;
esac
[[ $(git -C "$root" rev-parse --is-shallow-repository) == false ]] || {
  echo 'release-notes.sh: fetch full history before generating notes' >&2
  exit 1
}
work=$(mktemp -d "${TMPDIR:-/tmp}/atelier-release-notes.XXXXXX")
trap 'rm -rf "$work"' EXIT
range=("$head")
[[ -z $base ]] || range+=("^$base")
git -C "$root" rev-list "${range[@]}" >"$work/commits"
gh api "repos/$repository/pulls?state=closed&per_page=100" --paginate \
  --jq '.[] | select(.merged_at != null) | [.merge_commit_sha, .number, (.title | gsub("[\r\n\t]"; " ")), .html_url] | @tsv' >"$work/pulls"
awk -F '\t' '
  FILENAME == ARGV[1] { included[$1] = 1; next }
  included[$1] && !seen[$2]++ { printf "- %s ([#%s](%s))\n", $3, $2, $4 }
' "$work/commits" "$work/pulls" >"$work/changes"

if [[ $channel == dev ]]; then
  printf 'This rolling prerelease contains the newest development build.\n\n'
fi
cat <<NOTES
## Install or upgrade

Requires macOS 27 on Apple silicon.

Install:

\`\`\`sh
brew install --cask jeremytondo/tap/$token
\`\`\`

Upgrade:

\`\`\`sh
brew update
brew upgrade --cask $token
\`\`\`

After installing or upgrading, run \`atelier doctor\` to check the installation.
Only one channel can be installed at a time. See [installation and channel switching](https://github.com/$repository/blob/$head/docs/releases.md).

## What's Changed

NOTES
if [[ -s $work/changes ]]; then
  cat "$work/changes"
else
  echo 'No pull requests in this build since the previous stable release.'
fi
