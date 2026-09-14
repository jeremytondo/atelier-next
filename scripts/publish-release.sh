#!/usr/bin/env bash
# Only verified packages reach GitHub. Stable assets are never overwritten;
# dev publication is serialized by the workflow and rejects an obsolete source branch.
# shellcheck disable=SC2154  # release-plan fields are defined by load_release_plan
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# -eq 1 && -d $1 ]] || die 'usage: mise run release:publish ASSET_DIRECTORY'
assets=$(cd "$1" && pwd -P)
manifest="$assets/manifest.json"
load_release_plan "$manifest"
jq -e '.asset == "Atelier-macos-arm64.zip" and .architecture == "arm64" and
  .minimum_macos == "27.0" and .signing == "developer-id" and .notarized == true' "$manifest" > /dev/null || die 'expected a notarized arm64 release manifest'
for asset in Atelier-macos-arm64.zip manifest.json checksums.txt; do
  [[ -s $assets/$asset ]] || die "missing or empty release asset: $asset"
done
[[ $(awk '{print $2}' "$assets/checksums.txt") == $'Atelier-macos-arm64.zip\nmanifest.json' ]] || die 'checksums must cover exactly the ZIP and manifest'
(cd "$assets" && shasum -a 256 --check checksums.txt) || die 'release asset checksum mismatch'

cd "$root"
export GH_REPO=$repository
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-publish.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
if [[ $channel == dev ]]; then
  status=0
  "$root/scripts/release-current.sh" "$manifest" || status=$?
  [[ $status != 78 ]] || exit 0
  [[ $status == 0 ]] || exit "$status"
fi
gh api --paginate --slurp "repos/$GH_REPO/releases?per_page=100" > "$temporary/releases.json"
jq --arg tag "$tag" '[.[][] | select(.tag_name == $tag)][0] // null' "$temporary/releases.json" > "$temporary/existing.json"
existing=$(jq -r '.id // empty' "$temporary/existing.json")
files=("$assets/Atelier-macos-arm64.zip" "$manifest" "$assets/checksums.txt")
# Release notes contain literal Markdown backticks, never shell substitutions.
# shellcheck disable=SC2016
{
  printf 'Version: `%s`  \nCommit: [`%s`](https://github.com/%s/commit/%s)\n\n' "$version" "${commit:0:8}" "$GH_REPO" "$commit"
  printf 'Source branch:\n\n    %s\n\n' "${source_ref#refs/heads/}"
  printf 'Requires Apple silicon and macOS 27 or later. Signed with Developer ID and notarized by Apple.\n\n'
  printf 'Download `Atelier-macos-arm64.zip`, quit Atelier, and move the extracted app into `/Applications`. Your configuration is preserved.\n'
  if [[ $channel == dev ]]; then
    printf '\nThis rolling prerelease is replaced by successful manually requested dev builds from any branch. Stable releases retain their versioned downloads.\n'
  fi
} > "$temporary/notes.md"

if [[ $channel == stable ]]; then
  [[ -z $existing ]] || die "$tag already exists; stable releases are never overwritten (including drafts)."
  # Also refuse a pre-existing tag without a release. The workflow owns creation
  # of stable tags so a rebuilt package cannot accidentally identify other code.
  gh api --paginate --slurp "repos/$GH_REPO/git/matching-refs/tags/$tag" > "$temporary/tags.json"
  jq -e --arg ref "refs/tags/$tag" '[.[][] | select(.ref == $ref)] | length == 0' "$temporary/tags.json" > /dev/null || die "$tag already exists remotely"
  gh release create "$tag" "${files[@]}" --target "$commit" --title "$tag" \
    --notes-file "$temporary/notes.md" --draft
  gh release edit "$tag" --draft=false --latest
elif [[ -n $existing ]]; then
  jq -e '.immutable != true and .draft == false and .prerelease == true' "$temporary/existing.json" > /dev/null || die 'The dev release must be a mutable, published prerelease.'
  gh release upload dev "${files[@]}" --clobber
  gh api --method PATCH "repos/$GH_REPO/git/refs/tags/dev" -f "sha=$commit" -F force=true > /dev/null
  gh release edit dev --title "Atelier Dev — $version" --notes-file "$temporary/notes.md" --prerelease --latest=false
else
  gh release create dev "${files[@]}" --target "$commit" --title "Atelier Dev — $version" \
    --notes-file "$temporary/notes.md" --prerelease --latest=false --draft
  gh release edit dev --draft=false --prerelease --latest=false
fi
gh release view "$tag" --json url --jq .url
