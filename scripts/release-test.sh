#!/usr/bin/env bash
# Exercise release invariants against disposable Git history and a fake GitHub.
# No network, real signing credentials, app launch, or release mutation occurs.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-release-tests.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
  if "$@" > "$temporary/failure.log" 2>&1; then fail "unexpected success: $*"; fi
}
repo="$temporary/repository"
git init -q "$repo"
git -C "$repo" config user.name 'Release Test'
git -C "$repo" config user.email 'release-test@example.invalid'
git -C "$repo" commit -q --allow-empty -m Initial
commit=$(git -C "$repo" rev-parse HEAD)
export ATELIER_RELEASE_REPO_ROOT="$repo"
"$root/scripts/release-plan.sh" stable minor > "$temporary/stable.json"
[[ $(jq -r .tag "$temporary/stable.json") == v0.1.0 ]] || fail 'initial minor release'
"$root/scripts/release-plan.sh" stable patch > "$temporary/patch.json"
[[ $(jq -r .tag "$temporary/patch.json") == v0.0.1 ]] || fail 'initial patch release'
for tag in dev v1.9.0 v1.10.0 v20.0.0-beta.1 v01.20.0; do git -C "$repo" tag "$tag"; done
"$root/scripts/release-plan.sh" stable patch > "$temporary/patch.json"
[[ $(jq -r .tag "$temporary/patch.json") == v1.10.1 ]] || fail 'numeric SemVer sorting or prerelease filtering'
"$root/scripts/release-plan.sh" stable major > "$temporary/major.json"
[[ $(jq -r .tag "$temporary/major.json") == v2.0.0 ]] || fail 'major bump resets minor and patch'
"$root/scripts/release-plan.sh" stable minor > "$temporary/stable.json"
[[ $(jq -r .tag "$temporary/stable.json") == v1.11.0 ]] || fail 'minor bump'
"$root/scripts/release-plan.sh" dev > "$temporary/dev.json"
for channel in dev stable; do
  "$root/scripts/validate-release-plan.sh" "$temporary/$channel.json"
  [[ $(jq -r .commit "$temporary/$channel.json") == "$commit" ]] || fail 'plan lost exact source commit'
done
expect_failure "$root/scripts/release-plan.sh" stable banana
expect_failure "$root/scripts/release-plan.sh" dev patch
expect_failure "$root/scripts/release.sh" stable
expect_failure "$root/scripts/release.sh" dev --pr 2
expect_failure "$root/scripts/build-app.sh" --identity
jq '.tag = "v9.9.9"' "$temporary/stable.json" > "$temporary/bad-plan.json"
expect_failure "$root/scripts/validate-release-plan.sh" "$temporary/bad-plan.json"
jq '.build_number = "1"' "$temporary/stable.json" > "$temporary/bad-plan.json"
expect_failure "$root/scripts/validate-release-plan.sh" "$temporary/bad-plan.json"

mkdir -p "$temporary/bin" "$temporary/assets"
export FAKE_GH_LOG="$temporary/gh.log"
export FAKE_MAIN="$commit"
export FAKE_EXISTING='null'
export FAKE_TAGS='[]'
cat > "$temporary/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ $1 == api ]]; then
  case "$*" in
    *git/ref/heads/main*) jq -n --arg sha "$FAKE_MAIN" '{object: {sha: $sha}}' ;;
    *git/matching-refs/tags/*) jq -n --argjson refs "$FAKE_TAGS" '[$refs]' ;;
    *releases?per_page=100*) jq -n --argjson release "$FAKE_EXISTING" '[if $release == null then [] else [$release] end]' ;;
    *'--method PATCH'*) printf '{}\n' ;;
    *) echo "Unexpected fake API call: $*" >&2; exit 99 ;;
  esac
elif [[ $1 == release ]]; then
  case "$2" in create|edit|upload) ;; view) echo https://example.invalid/release ;; *) exit 99 ;; esac
else
  echo "Unexpected fake gh call: $*" >&2; exit 99
fi
FAKE_GH
chmod +x "$temporary/bin/gh"
export PATH="$temporary/bin:$PATH"
asset_dir="$temporary/assets"
make_assets() {
  printf 'packaged app\n' > "$asset_dir/Atelier-macos-arm64.zip"
  jq '. + {architecture: "arm64", minimum_macos: "26.0", signing: "developer-id", notarized: true,
    asset: "Atelier-macos-arm64.zip"}' "$temporary/$1.json" > "$asset_dir/manifest.json"
  (cd "$asset_dir" && shasum -a 256 Atelier-macos-arm64.zip manifest.json > checksums.txt)
  : > "$FAKE_GH_LOG"
}
publish() { "$root/scripts/publish-release.sh" "$asset_dir" > "$temporary/publish.log" 2>&1; }

make_assets stable
printf 'tampered\n' >> "$asset_dir/Atelier-macos-arm64.zip"
expect_failure publish
[[ ! -s $FAKE_GH_LOG ]] || fail 'tampered assets reached GitHub'
make_assets stable
printf 'unexpected checksums\n' > "$asset_dir/checksums.txt"
expect_failure publish
[[ ! -s $FAKE_GH_LOG ]] || fail 'incomplete checksum coverage reached GitHub'
make_assets stable
jq '.notarized = false' "$asset_dir/manifest.json" > "$temporary/unsigned.json"
mv "$temporary/unsigned.json" "$asset_dir/manifest.json"
expect_failure publish
[[ ! -s $FAKE_GH_LOG ]] || fail 'unsigned package reached GitHub'

make_assets dev
FAKE_MAIN=0000000000000000000000000000000000000000 publish
! grep -Eq '^release |--method PATCH' "$FAKE_GH_LOG" || fail 'stale dev build changed the release'
make_assets dev
publish
grep -Eq '^release create dev .*--prerelease --latest=false --draft$' "$FAKE_GH_LOG" || fail 'new dev release must be a prerelease'
grep -Eq '^release edit dev --draft=false --prerelease --latest=false$' "$FAKE_GH_LOG" || fail 'dev publication changed latest stable'
make_assets dev
FAKE_EXISTING='{"id":1,"tag_name":"dev","immutable":false,"draft":false,"prerelease":true}' publish
grep -Eq '^release upload dev .*--clobber$' "$FAKE_GH_LOG" || fail 'rolling dev assets were not replaced'
grep -Eq -- "--method PATCH .*git/refs/tags/dev -f sha=$commit -F force=true" "$FAKE_GH_LOG" || fail 'dev tag did not advance'
make_assets dev
FAKE_EXISTING='{"id":1,"tag_name":"dev","immutable":true,"draft":false,"prerelease":true}' expect_failure publish
! grep -Eq '^release |--method PATCH' "$FAKE_GH_LOG" || fail 'immutable dev release was modified'

make_assets stable
FAKE_EXISTING='{"id":1,"tag_name":"v1.11.0"}' expect_failure publish
! grep -Eq '^release |--method PATCH' "$FAKE_GH_LOG" || fail 'existing stable release was modified'
make_assets stable
FAKE_TAGS='[{"ref":"refs/tags/v1.11.0"}]' expect_failure publish
! grep -Eq '^release |--method PATCH' "$FAKE_GH_LOG" || fail 'existing stable tag was reused'
make_assets stable
publish
grep -Eq '^release create v1.11.0 .*--draft$' "$FAKE_GH_LOG" || fail 'stable release was not staged as a draft'
grep -Eq '^release edit v1.11.0 --draft=false --latest$' "$FAKE_GH_LOG" || fail 'stable release did not become latest'
! grep -Eq -- '--clobber|--method PATCH|--prerelease' "$FAKE_GH_LOG" || fail 'stable publication overwrote existing assets'

# Even a failing package command must restore keychains and delete imported keys.
mkdir -p "$temporary/runner with spaces"
export SECURITY_LOG="$temporary/security.log"
cat > "$temporary/bin/security" <<'FAKE_SECURITY'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SECURITY_LOG"
if [[ "$*" == 'list-keychains -d user' ]]; then
  printf '    "/tmp/Login Keychain.keychain-db"\n    "/tmp/Second.keychain-db"\n'
fi
FAKE_SECURITY
chmod +x "$temporary/bin/security"
# Expand the key path in the wrapped process, after ci-signing.sh sets it.
# shellcheck disable=SC2016
GITHUB_ACTIONS=true RUNNER_TEMP="$temporary/runner with spaces" \
  ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64=ZHVtbXk= \
  ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD=test \
  ATELIER_APP_STORE_CONNECT_KEY_BASE64=ZHVtbXk= \
  ATELIER_APP_STORE_CONNECT_KEY_ID=TEST ATELIER_APP_STORE_CONNECT_ISSUER_ID=TEST \
  expect_failure "$root/scripts/ci-signing.sh" sh -c 'test -f "$ATELIER_APP_STORE_CONNECT_KEY_PATH" || exit 99; exit 9'
grep -Eq '^list-keychains -d user -s /tmp/Login Keychain.keychain-db /tmp/Second.keychain-db$' "$SECURITY_LOG" || fail 'keychain search list was not restored'
grep -Eq '^delete-keychain ' "$SECURITY_LOG" || fail 'temporary keychain was not deleted'
[[ -z $(ls -A "$temporary/runner with spaces") ]] || fail 'temporary signing credentials were retained'
echo 'Release behavior tests passed.'
