#!/usr/bin/env bash
# Publish what scripts/package.sh made: the download first, then the tap. The
# tap is touched only once the published download has been fetched back and
# its checksum matches, and only the chosen channel's cask is written.
#
# Until the tap moves nothing points at the new download, so a failure before
# then takes back what this run put on GitHub and leaves everything as it was.
# After it, the new build is what people install, so nothing is taken back and
# what remains, tidying the rolling release, can simply be run again.
#
# A stable release is a new versioned GitHub release and is never overwritten.
# The dev channel is one rolling prerelease, tagged dev: the new archive is
# added beside the old one, the tap moves to it, and only then is the old one
# removed, so there is never a moment with nothing to download.
#
# usage: scripts/publish.sh DIST dev|stable TAG [--dry-run]
#   --dry-run  change nothing, and say what would be done. It reads the
#              archive and this repository's releases; it cannot tell whether
#              the tap's token works.
#
# Needs gh signed in (GH_TOKEN in CI) and ATELIER_TAP_TOKEN, a token that may
# push to the tap.
set -euo pipefail
repository=jeremytondo/atelier-next
tap=jeremytondo/homebrew-tap
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
die() {
  echo "publish.sh: $*" >&2
  exit 1
}

usage='usage: scripts/publish.sh DIST dev|stable TAG [--dry-run]'
# Exactly, so that a mistyped --dry-run is refused rather than run for real.
[[ $# -eq 3 || ($# -eq 4 && $4 == --dry-run) ]] || die "$usage"
dist=$1 channel=$2 tag=$3
dry=false
[[ $# -eq 4 ]] && dry=true
[[ $channel == dev || $channel == stable ]] || die "expected dev or stable, not $channel"
[[ $channel == dev && $tag != dev ]] && die 'the dev channel is published under the tag dev'
[[ $channel == stable && ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && die "a stable tag looks like v0.1.0, not $tag"

field() { plutil -extract "$1" raw -o - "$dist/release.json"; }
version=$(field version)
build=$(field build)
asset=$(field asset)
sha256=$(field sha256)
[[ $channel == dev || $tag == "v$version" ]] || die "the tag $tag does not name version $version"
# The cask asks for exactly this name, so any other would publish a cask
# that points at nothing.
[[ $asset == "Atelier-$version-$build.zip" ]] || die "the archive is called $asset, not Atelier-$version-$build.zip"
[[ -f $dist/$asset ]] || die "$dist/$asset is missing"
[[ $(shasum -a 256 "$dist/$asset" | cut -d ' ' -f 1) == "$sha256" ]] || die 'the archive does not match its recorded checksum'

# A dry run goes on past what would stop a real one, and says so at the end.
refused=false
if [[ $(field notarized) != true ]]; then
  $dry || die 'this archive was not notarized and must not be published'
  echo 'WARNING: this archive was not notarized; a real run refuses it.'
  refused=true
fi

# Everything that could refuse is asked before anything is created.
$dry || [[ -n ${ATELIER_TAP_TOKEN:-} ]] || die 'ATELIER_TAP_TOKEN is not set'
gh auth status >/dev/null 2>&1 || die 'gh is not signed in'
exists=false
gh release view "$tag" --repo "$repository" >/dev/null 2>&1 && exists=true
[[ $channel == stable ]] && $exists && die "the release $tag already exists; a stable release is never overwritten"
tag_exists=false
gh api "repos/$repository/git/ref/tags/$tag" >/dev/null 2>&1 && tag_exists=true

# The rolling release is this script's alone. One holding anything it did not
# name is somebody else's, such as the dev build of the Hammerspoon version, and
# is neither added to nor cleared out.
ours='^Atelier-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.zip$'
assets=''
if [[ $channel == dev ]] && $exists; then
  assets=$(gh release view "$tag" --repo "$repository" --json assets --jq '.assets[].name')
fi
others=$(grep -vE "$ours" <<<"$assets" | grep . || true)
# The builds this script made earlier, which the new one replaces.
earlier=$(grep -E "$ours" <<<"$assets" | grep -vxF "$asset" || true)
if [[ -n $others ]]; then
  message="the release $tag holds files this script did not make: $(paste -sd, - <<<"$others"). Delete that release once, then publish again."
  $dry || die "$message"
  echo "WARNING: $message A real run refuses."
  refused=true
fi

case $channel in
  dev) token='atelier@dev' ;;
  stable) token='atelier' ;;
esac
url="https://github.com/$repository/releases/download/$tag/$asset"
commit=$(git -C "$root" rev-parse HEAD)

if $dry; then
  $refused && echo 'A real run stops at the warnings above. With those put right, it would do this:'
  echo "Would publish $asset ($version, build $build) as $channel under $tag, from $commit."
  # A release that is somebody else's will have been deleted by then.
  if $exists && [[ -z $others ]]; then
    echo "Would add it to the existing release $tag."
  else
    echo "Would create the release $tag."
  fi
  echo "Would fetch $url back and compare it with $sha256."
  echo "Would write Casks/$token.rb in $tap and no other file:"
  "$root/scripts/cask.sh" "$channel" "$version" "$build" "$sha256" | sed 's/^/    /'
  if [[ $channel == dev ]]; then
    echo "Would then remove the builds it made earlier from $tag: ${earlier:-none}"
  fi
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/atelier-publish.XXXXXX")
created=false
uploaded=false
tap_moved=false
finish() {
  status=$?
  rm -rf "$work"
  if [[ $status -ne 0 ]] && ! $tap_moved; then
    # Nothing points at the new download yet, so it goes, and a second try
    # starts from where this one did. Said to be gone only when it is: what
    # stays behind has to be removed by hand, or it stops the next try.
    if $created; then
      cleanup=(--yes)
      $tag_exists || cleanup+=(--cleanup-tag)
      if gh release delete "$tag" --repo "$repository" "${cleanup[@]}" >/dev/null 2>&1; then
        echo "publish.sh: failed before the tap moved; the release $tag made by this run was removed" >&2
      else
        echo "publish.sh: failed before the tap moved, and the release $tag made by this run could NOT be removed. Delete it by hand before publishing again." >&2
      fi
    elif $uploaded; then
      if gh release delete-asset "$tag" "$asset" --repo "$repository" --yes >/dev/null 2>&1; then
        echo "publish.sh: failed before the tap moved; $asset was removed from $tag" >&2
      else
        echo "publish.sh: failed before the tap moved, and $asset could NOT be removed from $tag. Delete it by hand before publishing again." >&2
      fi
    fi
  fi
  exit "$status"
}
trap finish EXIT

if [[ $channel == stable ]]; then
  # A draft until the archive is up, so nobody sees a release with nothing in it.
  gh release create "$tag" --repo "$repository" --target "$commit" --title "Atelier $version" \
    --notes "Atelier $version, build $build." --draft "$dist/$asset"
  created=true
  gh release edit "$tag" --repo "$repository" --draft=false
elif $exists; then
  # Already there when an earlier run got as far as the tap and no further.
  if ! grep -qxF "$asset" <<<"$assets"; then
    gh release upload "$tag" --repo "$repository" "$dist/$asset"
    uploaded=true
  fi
else
  gh release create "$tag" --repo "$repository" --target "$commit" --title 'Atelier development build' \
    --notes "Atelier $version, build $build. This release always holds the newest development build." \
    --prerelease "$dist/$asset"
  created=true
fi

# What Homebrew will fetch, fetched the way Homebrew will.
curl --fail --silent --show-error --location --retry 5 --retry-delay 3 --output "$work/$asset" "$url"
[[ $(shasum -a 256 "$work/$asset" | cut -d ' ' -f 1) == "$sha256" ]] ||
  die "what $url serves does not match the archive; the tap was not touched"

# The token reaches git through a helper that reads it from the environment,
# so it is in no command line and in no file of the clone.
cat >"$work/askpass" <<'ASKPASS'
#!/bin/sh
case $1 in
  Username*) echo x-access-token ;;
  *) echo "$ATELIER_TAP_TOKEN" ;;
esac
ASKPASS
chmod 700 "$work/askpass"
git clone --quiet --depth 1 "https://github.com/$tap.git" "$work/tap"
mkdir -p "$work/tap/Casks"
"$root/scripts/cask.sh" "$channel" "$version" "$build" "$sha256" >"$work/tap/Casks/$token.rb"
git -C "$work/tap" add "Casks/$token.rb"
# Unchanged when an earlier run got this far already.
if ! git -C "$work/tap" diff --cached --quiet; then
  git -C "$work/tap" -c user.name='Atelier release' -c user.email='release@elevenideas.invalid' \
    commit --quiet -m "$token $version,$build"
  # No credential helper, which would otherwise be asked first and then be
  # given the token to keep.
  if ! GIT_ASKPASS="$work/askpass" GIT_TERMINAL_PROMPT=0 git -C "$work/tap" -c credential.helper= \
    push --quiet origin HEAD; then
    # A push can land and still report failure. Taking the archive back then
    # would leave the tap pointing at nothing, so the tap is asked what it
    # holds, and when it will not say, the archive stays.
    branch=$(git -C "$work/tap" rev-parse --abbrev-ref HEAD)
    theirs=$(git -C "$work/tap" ls-remote origin "refs/heads/$branch" | cut -f 1) || theirs=''
    if [[ $theirs == "$(git -C "$work/tap" rev-parse HEAD)" ]]; then
      echo 'publish.sh: the push reported failure, but the tap has the new cask' >&2
    elif [[ -z $theirs ]]; then
      tap_moved=true
      die "the push to $tap failed and the tap could not be asked whether it took it; $asset was kept. Look at the tap, then run this again."
    else
      die "the push to $tap was refused; the tap was not touched"
    fi
  fi
fi
tap_moved=true

if [[ $channel == dev ]]; then
  # The tap points at the new build now, so the earlier ones can go, and the
  # tag can say which commit the build is of.
  while read -r old; do
    [[ -z $old ]] || gh release delete-asset "$tag" "$old" --repo "$repository" --yes
  done <<<"$earlier"
  gh api --method PATCH "repos/$repository/git/refs/tags/$tag" -f sha="$commit" -F force=true >/dev/null
  gh release edit "$tag" --repo "$repository" \
    --notes "Atelier $version, build $build. This release always holds the newest development build."
fi
echo "Published $token $version,$build"
