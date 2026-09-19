#!/usr/bin/env bash
# Exercise release planning, dispatch, and publication against disposable
# history and fake GitHub/tap commands. No network, credentials, or external
# state are used.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-release-tests.XXXXXX")
temporary=$(cd "$temporary" && pwd -P)
trap 'rm -rf "$temporary"' EXIT
fail() {
  echo "release-test.sh: $*" >&2
  exit 1
}
expect_failure() {
  if "$@" >"$temporary/expected-failure.out" 2>&1; then
    fail "expected failure: $*"
  fi
}

# Stable planning uses only final SemVer tags, and every bump starts from the
# greatest one rather than from whichever tag Git happens to list last.
plan="$temporary/plan"
mkdir -p "$plan/scripts"
cp "$root/scripts/release-plan.sh" "$plan/scripts/"
git init -q "$plan"
git -C "$plan" config user.name 'Release Test'
git -C "$plan" config user.email 'release-test@example.invalid'
git -C "$plan" commit -q --allow-empty -m Initial
for tag in v1.9.0 v1.10.0 v20.0.0-beta.1 v01.20.0 v1.10.1-dev.20260101000000; do
  git -C "$plan" tag "$tag"
done
"$plan/scripts/release-plan.sh" patch >"$temporary/patch-plan"
grep -Fxq 'version=1.10.1' "$temporary/patch-plan" || fail 'patch plan did not follow the greatest stable tag'
"$plan/scripts/release-plan.sh" minor >"$temporary/minor-plan"
grep -Fxq 'version=1.11.0' "$temporary/minor-plan" || fail 'minor plan did not reset the patch'
"$plan/scripts/release-plan.sh" major >"$temporary/major-plan"
grep -Fxq 'version=2.0.0' "$temporary/major-plan" || fail 'major plan did not reset minor and patch'

# Homebrew quarantines cask downloads. The app keeps that protection, while
# the nested command must not wait forever on an app-launch confirmation that
# does not reliably surface from the terminal.
dev_cask="$temporary/atelier@dev.rb"
"$root/scripts/cask.sh" dev 0.0.1 20260918201812 \
  1111111111111111111111111111111111111111111111111111111111111111 >"$dev_cask"
ruby -c "$dev_cask" >/dev/null
grep -Fq 'run "/usr/bin/xattr"' "$dev_cask" || fail 'the cask does not make its command directly runnable'
grep -Fq 'args: ["-dr", "com.apple.quarantine", "{{appdir}}/Atelier.app/Contents/Helpers/atelier"]' "$dev_cask" ||
  fail 'the cask removes quarantine from something other than its command'

fakebin="$temporary/bin"
events="$temporary/events"
mkdir -p "$fakebin"
export FAKE_RELEASE_EVENTS="$events"
export FAKE_RELEASE_NOTES="$temporary/notes.md"
cat >"$fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"$FAKE_RELEASE_EVENTS"
args=("$@")
for ((i = 0; i < $#; i++)); do
  if [[ ${args[i]} == --notes-file ]]; then
    cp "${args[i + 1]}" "$FAKE_RELEASE_NOTES"
  fi
done
if [[ $1 == workflow && $2 == run ]]; then
  exit 0
fi
if [[ $1 == release && $2 == view ]]; then
  [[ ${FAKE_RELEASE_EXISTS:-false} == true ]] || exit 1
  printf '%s\n' "${FAKE_RELEASE_ASSETS:-}"
  exit 0
fi
if [[ $1 == api && $2 == *'/pulls?'* ]]; then
  [[ ${FAKE_NOTES_FAIL:-false} != true ]] || exit 1
  cat "$FAKE_PULLS"
  exit 0
fi
if [[ $1 == api && "$*" == *'/git/ref/tags/'* && "$*" != *'--method PATCH'* ]]; then
  [[ ${FAKE_TAG_EXISTS:-false} == true ]] || exit 1
fi
exit 0
FAKE_GH
cat >"$fakebin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == check-ref-format ]]; then
  exec /usr/bin/git "$@"
fi
if [[ $1 == -C && $2 == "$FAKE_REAL_REPO" ]]; then
  exec /usr/bin/git "$@"
fi
printf 'git %s\n' "$*" >>"$FAKE_RELEASE_EVENTS"
args=" $* "
if [[ $1 == clone ]]; then
  mkdir -p "${!#}"
elif [[ $args == *' diff --cached --quiet '* ]]; then
  exit 1
elif [[ $args == *' push '* && ${FAKE_PUSH_FAIL:-false} == true ]]; then
  exit 1
elif [[ $args == *' rev-parse --abbrev-ref HEAD '* ]]; then
  echo main
elif [[ $args == *' ls-remote '* ]]; then
  printf '0000000000000000000000000000000000000000\trefs/heads/main\n'
elif [[ $args == *' rev-parse HEAD '* ]]; then
  echo 1111111111111111111111111111111111111111
elif [[ $args == *' rev-parse --is-shallow-repository '* ]]; then
  echo false
elif [[ $args == *' tag --merged '* ]]; then
  printf '%s\n' "${FAKE_STABLE_TAGS:-}"
elif [[ $args == *' rev-list '* ]]; then
  echo 1111111111111111111111111111111111111111
fi
FAKE_GIT
cat >"$fakebin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$FAKE_RELEASE_EVENTS"
output=''
while [[ $# -gt 0 ]]; do
  if [[ $1 == --output ]]; then
    output=$2
    shift 2
  else
    shift
  fi
done
[[ -n $output ]]
cp "$FAKE_RELEASE_ARCHIVE" "$output"
FAKE_CURL
chmod +x "$fakebin/gh" "$fakebin/git" "$fakebin/curl"
export PATH="$fakebin:$PATH"
export FAKE_REAL_REPO="$plan" FAKE_PULLS="$temporary/pulls.tsv"

# Notes use actual ancestry, not merge dates or PR titles. Include two PRs
# sharing a merge commit, and exclude an old PR and a PR from another branch.
cp "$root/scripts/release-notes.sh" "$plan/scripts/"
base=$(git -C "$plan" rev-parse HEAD)
git -C "$plan" commit -q --allow-empty -m 'A change without a PR number'
head=$(git -C "$plan" rev-parse HEAD)
{
  printf '%s\t10\tFirst change\thttps://example.invalid/pull/10\n' "$head"
  printf '%s\t11\tSecond change\thttps://example.invalid/pull/11\n' "$head"
  printf '%s\t9\tAlready released\thttps://example.invalid/pull/9\n' "$base"
  printf '%s\t12\tAnother branch\thttps://example.invalid/pull/12\n' other
} >"$FAKE_PULLS"
"$plan/scripts/release-notes.sh" dev "$head" "$base" >"$temporary/range-notes"
grep -Fq -- '- First change ([#10](https://example.invalid/pull/10))' "$temporary/range-notes" || fail 'notes missed a PR'
grep -Fq -- '- Second change ([#11](https://example.invalid/pull/11))' "$temporary/range-notes" || fail 'notes lost a PR sharing a commit'
! grep -Eq 'Already released|Another branch' "$temporary/range-notes" || fail 'notes included a PR outside the range'
"$plan/scripts/release-notes.sh" stable "$head" >"$temporary/first-notes"
grep -Fq 'Already released' "$temporary/first-notes" || fail 'first release omitted earlier history'
"$plan/scripts/release-notes.sh" dev "$head" "$head" >"$temporary/empty-notes"
grep -Fq 'No pull requests in this build' "$temporary/empty-notes" || fail 'empty range was not explained'
printf '%s\t45\tMake the CLI runnable\thttps://example.invalid/pull/45\n' \
  1111111111111111111111111111111111111111 >"$FAKE_PULLS"

# Both the established task names and the argument-based task dispatch an
# explicit branch ref and do not silently accept a tag of the same name.
: >"$events"
MISE_CACHE_DIR="$temporary/mise-cache" mise run release:dev feature/release-test >/dev/null
grep -Fxq 'gh workflow run release.yml --repo jeremytondo/atelier-next --ref refs/heads/feature/release-test -f bump=dev' "$events" ||
  fail 'release:dev did not dispatch its branch'
: >"$events"
MISE_CACHE_DIR="$temporary/mise-cache" mise run release patch candidate >/dev/null
grep -Fxq 'gh workflow run release.yml --repo jeremytondo/atelier-next --ref refs/heads/candidate -f bump=patch' "$events" ||
  fail 'release patch did not dispatch its branch'
expect_failure "$root/scripts/release-dispatch.sh" dev 'bad..branch'

dist="$temporary/dist"
mkdir -p "$dist"
asset='Atelier-0.0.1-20260918201812.zip'
printf 'notarized native archive fixture\n' >"$dist/$asset"
sha256=$(shasum -a 256 "$dist/$asset" | cut -d ' ' -f 1)
cat >"$dist/release.json" <<JSON
{"version":"0.0.1","build":"20260918201812","asset":"$asset","sha256":"$sha256","notarized":true}
JSON
export FAKE_RELEASE_ARCHIVE="$dist/$asset"
export FAKE_RELEASE_EXISTS=true FAKE_TAG_EXISTS=true ATELIER_TAP_TOKEN=fixture
legacy_assets=$'Atelier-macos-arm64.zip\nchecksums.txt\nmanifest.json'
export FAKE_RELEASE_ASSETS="$legacy_assets"
publish() { "$root/scripts/publish.sh" "$dist" "$@"; }

# The first native dev release keeps the known legacy downloads until the new
# archive is verified and the tap moves, then removes exactly those files.
: >"$events"
publish dev dev >"$temporary/publish.out"
for old in Atelier-macos-arm64.zip checksums.txt manifest.json; do
  grep -Fq "gh release delete-asset dev $old --repo jeremytondo/atelier-next --yes" "$events" ||
    fail "legacy asset was not retired: $old"
done
upload_line=$(grep -nF "gh release upload dev --repo jeremytondo/atelier-next $dist/$asset" "$events" | cut -d: -f1)
push_line=$(grep -n 'git .* push ' "$events" | cut -d: -f1)
delete_line=$(grep -nF 'gh release delete-asset dev Atelier-macos-arm64.zip' "$events" | cut -d: -f1)
[[ $upload_line -lt $push_line && $push_line -lt $delete_line ]] || fail 'legacy assets moved before the tap'
grep -Fq "gh release edit dev --repo jeremytondo/atelier-next --title Atelier Dev 0.0.1-dev.20260918201812 --prerelease --latest=false" "$events" ||
  fail 'rolling release metadata was not normalized'
grep -Fxq 'brew install --cask jeremytondo/tap/atelier@dev' "$FAKE_RELEASE_NOTES" || fail 'dev install command missing'
grep -Fxq 'brew upgrade --cask atelier@dev' "$FAKE_RELEASE_NOTES" || fail 'dev upgrade command missing'
grep -Fxq "## What's Changed" "$FAKE_RELEASE_NOTES" || fail 'changes heading missing'
grep -Fq 'Make the CLI runnable ([#45]' "$FAKE_RELEASE_NOTES" || fail 'published notes omitted the PR'

# Updating a rolling release uses stable history, regardless of the dev tag.
: >"$events"
export FAKE_STABLE_TAGS=$'v0.0.0\nv0.0.1-dev.123'
export FAKE_RELEASE_ASSETS="$asset"
publish dev dev >"$temporary/retry.out"
grep -Fq 'rev-list 1111111111111111111111111111111111111111 ^v0.0.0' "$events" ||
  fail 'rolling release did not use the stable baseline'
unset FAKE_STABLE_TAGS
export FAKE_RELEASE_ASSETS="$legacy_assets"

# A failed PR lookup stops publication before any external state changes.
: >"$events"
export FAKE_NOTES_FAIL=true
expect_failure publish dev dev
! grep -Eq '^gh release (create|upload|edit|delete)' "$events" || fail 'failed notes lookup mutated a release'
! grep -Eq '^git .* push ' "$events" || fail 'failed notes lookup reached the tap'
unset FAKE_NOTES_FAIL

# Dry runs preview the full title and notes without writing to GitHub.
: >"$events"
publish dev dev --dry-run >"$temporary/dry.out"
grep -Fxq 'Title: Atelier Dev 0.0.1-dev.20260918201812' "$temporary/dry.out" || fail 'dry run omitted the title'
grep -Fxq "## What's Changed" "$temporary/dry.out" || fail 'dry run omitted the notes'
! grep -Eq '^gh release (create|upload|edit|delete)' "$events" || fail 'dry run mutated a release'

# A failed tap push removes only the native upload and retains the legacy set,
# so the old published state remains usable and the next run can retry.
: >"$events"
export FAKE_PUSH_FAIL=true
expect_failure publish dev dev
grep -Fq "gh release delete-asset dev $asset --repo jeremytondo/atelier-next --yes" "$events" ||
  fail 'failed publication did not roll back its native upload'
for old in Atelier-macos-arm64.zip checksums.txt manifest.json; do
  ! grep -Fq "gh release delete-asset dev $old" "$events" || fail "failed publication removed $old"
done
unset FAKE_PUSH_FAIL

# The migration allowlist is narrow: an unknown file refuses the run before
# an upload, tap push, or deletion can happen.
: >"$events"
export FAKE_RELEASE_ASSETS="$legacy_assets"$'\nnotes-from-someone.txt'
expect_failure publish dev dev
! grep -Eq '^gh release (upload|delete-asset)' "$events" || fail 'unknown release asset was mutated'
! grep -Eq '^git .* push ' "$events" || fail 'unknown release asset reached the tap'

# Stable publication uses a fresh versioned release and does not touch dev.
: >"$events"
export FAKE_RELEASE_EXISTS=false FAKE_TAG_EXISTS=false FAKE_RELEASE_ASSETS=''
publish stable v0.0.1 >"$temporary/stable-publish.out"
grep -Eq "^gh release create v0.0.1 .* --title Atelier 0.0.1 --notes-file .* --draft $dist/$asset$" "$events" ||
  fail 'stable release was not created as a draft'
! grep -Eq '^gh release delete-asset dev ' "$events" || fail 'stable publication touched dev assets'
grep -Fxq 'brew install --cask jeremytondo/tap/atelier' "$FAKE_RELEASE_NOTES" || fail 'stable install command missing'
grep -Fxq 'brew upgrade --cask atelier' "$FAKE_RELEASE_NOTES" || fail 'stable upgrade command missing'

# Stable boundaries ignore dev tags and choose the greatest final version.
: >"$events"
export FAKE_STABLE_TAGS=$'v0.0.0\nv0.0.1\nv0.0.1-dev.123\nv00.1.0'
publish stable v0.0.1 >"$temporary/stable-range.out"
grep -Fq 'rev-list 1111111111111111111111111111111111111111 ^v0.0.0' "$events" || fail 'stable range used the wrong tag'

# Creating a new rolling release uses the same title and notes as updating it.
: >"$events"
export FAKE_STABLE_TAGS=v0.0.0
publish dev dev >"$temporary/first-dev.out"
grep -Fq -- '--title Atelier Dev 0.0.1-dev.20260918201812 --notes-file' "$events" || fail 'first dev release used the wrong title'
grep -Fq 'rev-list 1111111111111111111111111111111111111111 ^v0.0.0' "$events" || fail 'first dev did not fall back to stable'

echo 'Release behavior tests passed.'
