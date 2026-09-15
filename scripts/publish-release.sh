#!/usr/bin/env bash
# Only verified packages reach GitHub and the tap. Stable releases are never
# overwritten; a dev release replaces the previous dev release after it is
# published, and an obsolete source branch is rejected before any mutation.
# shellcheck disable=SC2154  # manifest fields are defined by load_release_plan
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# -eq 1 && -d $1 ]] || die 'usage: mise run release:publish ASSET_DIRECTORY'
assets=$(cd "$1" && pwd -P)
manifest="$assets/manifest.json"
load_release_plan "$manifest"
jq -e '.architecture == "arm64" and .minimum_macos == "27.0" and .signing == "developer-id" and
  .notarized == true and (.asset | test("^atelier-.*-macos-arm64\\.tar\\.gz$")) and
  (.sha256 | test("^[0-9a-f]{64}$"))' "$manifest" > /dev/null || die 'expected a notarized arm64 release manifest'
asset=$(jq -r .asset "$manifest")
[[ $asset == "atelier-$version-macos-arm64.tar.gz" ]] || die 'the asset name must follow the version'
for file in "$asset" manifest.json checksums.txt; do
  [[ -s $assets/$file ]] || die "missing or empty release asset: $file"
done
[[ $(awk '{print $2}' "$assets/checksums.txt") == "$asset"$'\n'manifest.json ]] || die 'checksums must cover exactly the package and manifest'
(cd "$assets" && shasum -a 256 --check checksums.txt) || die 'release asset checksum mismatch'
[[ $(shasum -a 256 "$assets/$asset" | awk '{print $1}') == $(jq -r .sha256 "$manifest") ]] || die 'manifest sha256 does not match the package'

cd "$root"
export GH_REPO=$repository
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-publish.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
jq -e .hammerspoon2 "$manifest" > "$temporary/pin.json"
jq -e .hammerspoon2_artifact "$manifest" > "$temporary/hs2.json"
"$root/scripts/validate-hammerspoon.sh" "$temporary/pin.json" "$temporary/hs2.json" "$assets/hammerspoon2/Hammerspoon.2.zip"
jq -Se . "$temporary/hs2.json" > "$temporary/expected-hs2.json"
jq -Se . "$assets/hammerspoon2/manifest.json" > "$temporary/packaged-hs2.json"
cmp "$temporary/expected-hs2.json" "$temporary/packaged-hs2.json" || die 'Packaged HS2 manifest differs from the Atelier release manifest.'
if [[ $channel == dev ]]; then
  status=0
  "$root/scripts/release-current.sh" "$manifest" || status=$?
  [[ $status != 78 ]] || exit 0
  [[ $status == 0 ]] || exit "$status"
fi
gh api --paginate --slurp "repos/$GH_REPO/releases?per_page=100" > "$temporary/releases.json"
jq --arg tag "$tag" '[.[][] | select(.tag_name == $tag)][0] // null' "$temporary/releases.json" > "$temporary/existing.json"
[[ $(jq -r '.id // empty' "$temporary/existing.json") == '' ]] || die "$tag already exists; releases are never overwritten (including drafts)."
# Also refuse a pre-existing tag without a release. The workflow owns creation
# of release tags so a rebuilt package cannot accidentally identify other code.
gh api --paginate --slurp "repos/$GH_REPO/git/matching-refs/tags/$tag" > "$temporary/tags.json"
jq -e --arg ref "refs/tags/$tag" '[.[][] | select(.ref == $ref)] | length == 0' "$temporary/tags.json" > /dev/null || die "$tag already exists remotely"
files=("$assets/$asset" "$manifest" "$assets/checksums.txt")
# Release notes contain literal Markdown backticks, never shell substitutions.
# shellcheck disable=SC2016
{
  printf 'Version: `%s`  \nCommit: [`%s`](https://github.com/%s/commit/%s)\n\n' "$version" "${commit:0:8}" "$GH_REPO" "$commit"
  printf 'Source branch:\n\n    %s\n\n' "${source_ref#refs/heads/}"
  printf 'Requires Apple silicon and macOS 27 or later. The providers binary is signed with Developer ID and notarized by Apple.\n\n'
  if [[ $channel == dev ]]; then
    printf 'Install with `brew tap jeremytondo/atelier && brew install --cask atelier@dev`. Each dev release replaces the previous one; stable releases keep their downloads.\n'
  else
    printf 'Install with `brew tap jeremytondo/atelier && brew install --cask atelier`, or `brew upgrade` an existing install. Your configuration is preserved.\n'
  fi
} > "$temporary/notes.md"

# Validate both casks and tap credentials before publishing any release.
casks="$temporary/casks"
"$root/scripts/casks.sh" "$casks" "$manifest" > /dev/null
remote=${ATELIER_TAP_REMOTE:-}
if [[ -z $remote ]]; then
  [[ -n ${ATELIER_TAP_TOKEN:-} ]] || die 'ATELIER_TAP_TOKEN (or ATELIER_TAP_REMOTE) is required to push the casks'
  remote="https://x-access-token:${ATELIER_TAP_TOKEN}@github.com/jeremytondo/homebrew-atelier.git"
fi

# Permanent HS2 snapshots are published before any cask can reference them.
# A matching completed release is reused; an incomplete or different one fails.
if [[ $(jq -r .kind "$temporary/hs2.json") == snapshot ]]; then
  hs2_tag=$(jq -r .tag "$temporary/hs2.json")
  jq --arg tag "$hs2_tag" '[.[][] | select(.tag_name == $tag)][0] // null' "$temporary/releases.json" > "$temporary/existing-hs2.json"
  if [[ $(jq -r .id "$temporary/existing-hs2.json") != null ]]; then
    jq -e '.draft == false' "$temporary/existing-hs2.json" > /dev/null || die 'Existing HS2 snapshot is an incomplete draft.'
    gh release download "$hs2_tag" --repo "$repository" --dir "$temporary/published-hs2" --pattern manifest.json --pattern Hammerspoon.2.zip
    "$root/scripts/validate-hammerspoon.sh" "$temporary/pin.json" "$temporary/published-hs2/manifest.json" "$temporary/published-hs2/Hammerspoon.2.zip"
    jq -Se . "$temporary/published-hs2/manifest.json" > "$temporary/published-hs2.json"
    cmp "$temporary/expected-hs2.json" "$temporary/published-hs2.json" || die 'Existing HS2 snapshot differs; refusing to overwrite it.'
  else
    gh api --paginate --slurp "repos/$GH_REPO/git/matching-refs/tags/$hs2_tag" > "$temporary/hs2-tags.json"
    jq -e --arg ref "refs/tags/$hs2_tag" '[.[][] | select(.ref == $ref)] | length == 0' "$temporary/hs2-tags.json" > /dev/null || die 'HS2 tag already exists without a completed release.'
    printf 'Unpatched Hammerspoon 2, built and signed by Atelier.\n\nUpstream commit: %s\nBuild: %s\n' \
      "$(jq -r .revision "$temporary/pin.json")" "$(jq -r .build "$temporary/pin.json")" > "$temporary/hs2-notes.md"
    gh release create "$hs2_tag" "$assets/hammerspoon2/Hammerspoon.2.zip" "$assets/hammerspoon2/manifest.json" \
      --repo "$repository" --target "$commit" --title "Hammerspoon 2 snapshot $(jq -r .build "$temporary/pin.json")" \
      --notes-file "$temporary/hs2-notes.md" --prerelease --latest=false --draft
    gh release edit "$hs2_tag" --repo "$repository" --draft=false --prerelease --latest=false
  fi
fi

if [[ $channel == stable ]]; then
  gh release create "$tag" "${files[@]}" --target "$commit" --title "$tag" \
    --notes-file "$temporary/notes.md" --draft
  gh release edit "$tag" --draft=false --latest
else
  gh release create "$tag" "${files[@]}" --target "$commit" --title "Atelier Dev $version" \
    --notes-file "$temporary/notes.md" --prerelease --latest=false --draft
  gh release edit "$tag" --draft=false --prerelease --latest=false
fi
gh release view "$tag" --json url --jq .url > "$temporary/url"
url=$(cat "$temporary/url")

git clone --quiet --depth 1 --branch main "$remote" "$temporary/tap"
mkdir -p "$temporary/tap/Casks"
cp "$casks"/*.rb "$temporary/tap/Casks/"
git -C "$temporary/tap" add Casks
if ! git -C "$temporary/tap" diff --cached --quiet; then
  git -C "$temporary/tap" -c user.name='Atelier Release' -c user.email='releases@atelier.invalid' \
    commit --quiet -m "Atelier $version" -m "Casks generated by $GH_REPO@${commit:0:8}"
  git -C "$temporary/tap" push --quiet origin HEAD
fi
echo "Casks pushed: $(cd "$casks" && printf '%s ' *.rb)"

if [[ $channel == dev ]]; then
  # Only after the new dev release is public and the tap points at it.
  jq -r --arg tag "$tag" '.[][] | select(.prerelease == true and .draft == false and (.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+-dev\\.[0-9]{14}$")) and .tag_name != $tag) | .tag_name' "$temporary/releases.json" \
    | while IFS= read -r previous; do
        gh release delete "$previous" --yes --cleanup-tag
        echo "Deleted previous dev release $previous"
      done
fi
echo "$url"
