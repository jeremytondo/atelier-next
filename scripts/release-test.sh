#!/usr/bin/env bash
# Exercise release planning, dispatch, and publication against disposable
# history and fake GitHub/tap commands. No network, credentials, or external
# state are used.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-release-tests.XXXXXX")
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

fakebin="$temporary/bin"
events="$temporary/events"
mkdir -p "$fakebin"
export FAKE_RELEASE_EVENTS="$events"
cat >"$fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"$FAKE_RELEASE_EVENTS"
if [[ $1 == workflow && $2 == run ]]; then
  exit 0
fi
if [[ $1 == release && $2 == view ]]; then
  [[ ${FAKE_RELEASE_EXISTS:-false} == true ]] || exit 1
  printf '%s\n' "${FAKE_RELEASE_ASSETS:-}"
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
grep -Fq "gh release edit dev --repo jeremytondo/atelier-next --title Atelier development build --prerelease --latest=false" "$events" ||
  fail 'rolling release metadata was not normalized'

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
grep -Fq "gh release create v0.0.1 --repo jeremytondo/atelier-next --target 1111111111111111111111111111111111111111 --title Atelier 0.0.1 --notes Atelier 0.0.1, build 20260918201812. --draft $dist/$asset" "$events" ||
  fail 'stable release was not created as a draft'
! grep -Eq '^gh release delete-asset dev ' "$events" || fail 'stable publication touched dev assets'

echo 'Release behavior tests passed.'
