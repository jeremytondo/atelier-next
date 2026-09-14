#!/usr/bin/env bash
# Exercise release invariants against disposable Git history and a fake GitHub.
# No network, real signing credentials, app launch, or release mutation occurs.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-release-tests.XXXXXX")
# These fixtures also run inside a real CI release wrapper. Never mark that
# outer release obsolete while exercising a fake stale branch revision.
export ATELIER_STALE_DEV_MARKER="$temporary/obsolete-fixture"
unset GITHUB_REF
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
  [[ $(jq -r .source_ref "$temporary/$channel.json") == refs/heads/main ]] || fail 'default source branch'
done
expect_failure "$root/scripts/release-plan.sh" stable banana
expect_failure "$root/scripts/release-plan.sh" dev branch extra
expect_failure "$root/scripts/release-plan.sh" dev ''
expect_failure "$root/scripts/release-plan.sh" dev 'bad..branch'
GITHUB_REF=refs/tags/dev expect_failure "$root/scripts/release-plan.sh" dev
branch='feature/ATE-37#candidate'
GITHUB_REF="refs/heads/$branch" "$root/scripts/release-plan.sh" dev > "$temporary/branch.json"
"$root/scripts/validate-release-plan.sh" "$temporary/branch.json"
[[ $(jq -r .source_ref "$temporary/branch.json") == "refs/heads/$branch" ]] || fail 'CI plan lost dispatched branch'
"$root/scripts/release-plan.sh" stable patch "$branch" > "$temporary/branch-stable.json"
[[ $(jq -r .source_ref "$temporary/branch-stable.json") == "refs/heads/$branch" ]] || fail 'explicit stable source branch'
git clone -q --depth 1 "file://$repo" "$temporary/shallow"
ATELIER_RELEASE_REPO_ROOT="$temporary/shallow" "$root/scripts/release-plan.sh" dev > "$temporary/shallow-dev.json"
"$root/scripts/validate-release-plan.sh" "$temporary/shallow-dev.json"
ATELIER_RELEASE_REPO_ROOT="$temporary/shallow" expect_failure "$root/scripts/release-plan.sh" stable patch
expect_failure "$root/scripts/build-app.sh" --identity
jq '.tag = "v9.9.9"' "$temporary/stable.json" > "$temporary/bad-plan.json"
expect_failure "$root/scripts/validate-release-plan.sh" "$temporary/bad-plan.json"
jq '.build_number = "1"' "$temporary/stable.json" > "$temporary/bad-plan.json"
expect_failure "$root/scripts/validate-release-plan.sh" "$temporary/bad-plan.json"
for ref in refs/tags/dev refs/heads/bad..branch refs/heads/; do
  jq --arg ref "$ref" '.source_ref = $ref' "$temporary/dev.json" > "$temporary/bad-plan.json"
  expect_failure "$root/scripts/validate-release-plan.sh" "$temporary/bad-plan.json"
done
jq 'del(.source_ref)' "$temporary/dev.json" > "$temporary/bad-plan.json"
expect_failure "$root/scripts/validate-release-plan.sh" "$temporary/bad-plan.json"

mkdir -p "$temporary/bin" "$temporary/assets"
export FAKE_GH_LOG="$temporary/gh.log"
export FAKE_REMOTE_COMMIT="$commit"
export FAKE_EXISTING='null'
export FAKE_TAGS='[]'
cat > "$temporary/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
[[ ${FAKE_GH_FAIL:-false} == false ]] || exit 99
if [[ $1 == api ]]; then
  case "$*" in
    *git/ref/heads/"${FAKE_ENCODED_BRANCH:-main}") jq -n --arg sha "$FAKE_REMOTE_COMMIT" '{object: {sha: $sha}}' ;;
    *git/ref/heads/"${FAKE_ENCODED_BRANCH:-main} --silent") ;;
    *git/matching-refs/tags/*) jq -n --argjson refs "$FAKE_TAGS" '[$refs]' ;;
    *releases?per_page=100*) jq -n --argjson release "$FAKE_EXISTING" '[if $release == null then [] else [$release] end]' ;;
    *'--method PATCH'*) printf '{}\n' ;;
    *) echo "Unexpected fake API call: $*" >&2; exit 99 ;;
  esac
elif [[ $1 == release ]]; then
  case "$2" in create|edit|upload) ;; view) echo https://example.invalid/release ;; *) exit 99 ;; esac
elif [[ $1 == workflow && $2 == run ]]; then
  :
else
  echo "Unexpected fake gh call: $*" >&2; exit 99
fi
FAKE_GH
chmod +x "$temporary/bin/gh"
export PATH="$temporary/bin:$PATH"
: > "$FAKE_GH_LOG"
"$root/scripts/release-dispatch.sh" dev
grep -Fxq 'workflow run release.yml --ref refs/heads/main -f bump=dev' "$FAKE_GH_LOG" || fail 'default dev dispatch'
export FAKE_ENCODED_BRANCH='feature%2FATE-37%23candidate'
for bump in dev patch minor major; do
  : > "$FAKE_GH_LOG"
  "$root/scripts/release-dispatch.sh" "$bump" "$branch"
  grep -Fxq "workflow run release.yml --ref refs/heads/$branch -f bump=$bump" "$FAKE_GH_LOG" || fail 'branch dispatch'
done
: > "$FAKE_GH_LOG"
FAKE_GH_FAIL=true expect_failure "$root/scripts/release-dispatch.sh" dev "$branch"
! grep -q '^workflow ' "$FAKE_GH_LOG" || fail 'missing branch still dispatched'
expect_failure "$root/scripts/release-dispatch.sh" dev 'bad..branch'
expect_failure "$root/scripts/release-dispatch.sh" dev ''
expect_failure "$root/scripts/release-dispatch.sh" banana
unset FAKE_ENCODED_BRANCH
asset_dir="$temporary/assets"
make_assets() {
  printf 'packaged app\n' > "$asset_dir/Atelier-macos-arm64.zip"
  jq '. + {architecture: "arm64", minimum_macos: "27.0", signing: "developer-id", notarized: true,
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
FAKE_REMOTE_COMMIT=0000000000000000000000000000000000000000 publish
! grep -Eq '^release |--method PATCH' "$FAKE_GH_LOG" || fail 'stale dev build changed the release'
"$root/scripts/release-current.sh" "$temporary/dev.json"
FAKE_REMOTE_COMMIT=0000000000000000000000000000000000000000 expect_failure "$root/scripts/release-current.sh" "$temporary/dev.json"
FAKE_GH_FAIL=true expect_failure "$root/scripts/release-current.sh" "$temporary/dev.json"
FAKE_GH_FAIL=true "$root/scripts/release-current.sh" "$temporary/stable.json"
GITHUB_OUTPUT="$temporary/stale-output" FAKE_REMOTE_COMMIT=0000000000000000000000000000000000000000 \
  "$root/scripts/ci-release.sh" "$temporary/dev.json"
[[ $(cat "$temporary/stale-output") == packaged=false ]] || fail 'obsolete release was not skipped before credentials/builds'
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

export FAKE_ENCODED_BRANCH='feature%2FATE-37%23candidate'
"$root/scripts/release-current.sh" "$temporary/branch.json"
make_assets branch
publish
grep -Eq '^release create dev .*--prerelease --latest=false --draft$' "$FAKE_GH_LOG" || fail 'branch dev was not published'
make_assets branch
FAKE_REMOTE_COMMIT=0000000000000000000000000000000000000000 publish
! grep -Eq '^release |--method PATCH' "$FAKE_GH_LOG" || fail 'stale branch dev changed the release'
make_assets branch
FAKE_GH_FAIL=true expect_failure publish
! grep -Eq '^release |--method PATCH' "$FAKE_GH_LOG" || fail 'unavailable branch changed the release'
GITHUB_OUTPUT="$temporary/stale-branch-output" FAKE_REMOTE_COMMIT=0000000000000000000000000000000000000000 \
  "$root/scripts/ci-release.sh" "$temporary/branch.json"
[[ $(cat "$temporary/stale-branch-output") == packaged=false ]] || fail 'obsolete branch was not skipped before credentials/builds'
make_assets branch-stable
publish
grep -Eq '^release create v1.10.1 .*--draft$' "$FAKE_GH_LOG" || fail 'branch stable was not published'
! grep -q 'git/ref/heads/' "$FAKE_GH_LOG" || fail 'stable must retain its selected commit'
unset FAKE_ENCODED_BRANCH

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
elif [[ $1 == find-identity && ${FAKE_SIGNING_VALID:-true} == true ]]; then
  printf '  1) 1111111111111111111111111111111111111111 "Developer ID Application: Fixture (TEST)"\n'
fi
FAKE_SECURITY
chmod +x "$temporary/bin/security"
printf '#!/usr/bin/env bash\necho fixture-uuid\n' > "$temporary/bin/uuidgen"
chmod +x "$temporary/bin/uuidgen"
mkdir -p "$temporary/Xcode/usr/bin"
touch "$temporary/Xcode/usr/bin/notarytool" "$temporary/Xcode/usr/bin/stapler"
chmod +x "$temporary/Xcode/usr/bin/"*
signing() {
  GITHUB_ACTIONS=true RUNNER_TEMP="$temporary/runner with spaces" DEVELOPER_DIR="$temporary/Xcode" \
    ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64=ZHVtbXk= \
    ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD=test \
    ATELIER_APP_STORE_CONNECT_KEY_BASE64=ZHVtbXk= \
    ATELIER_APP_STORE_CONNECT_KEY_ID=TEST ATELIER_APP_STORE_CONNECT_ISSUER_ID=TEST \
    "$root/scripts/ci-signing.sh" "$@"
}
# Expand the key path in the wrapped process, after ci-signing.sh sets it.
# shellcheck disable=SC2016
expect_failure signing sh -c 'test -f "$ATELIER_APP_STORE_CONNECT_KEY_PATH" || exit 99; touch "$1"; exit 9' sh "$temporary/wrapped"
[[ -f $temporary/wrapped ]] || fail 'valid signing preflight did not reach the wrapped command'
rm "$temporary/wrapped"
FAKE_SIGNING_VALID=false expect_failure signing touch "$temporary/wrapped"
[[ ! -f $temporary/wrapped ]] || fail 'invalid signing identity reached expensive work'
grep -Eq '^list-keychains -d user -s /tmp/Login Keychain.keychain-db /tmp/Second.keychain-db$' "$SECURITY_LOG" || fail 'keychain search list was not restored'
grep -Eq '^delete-keychain ' "$SECURITY_LOG" || fail 'temporary keychain was not deleted'
[[ -z $(ls -A "$temporary/runner with spaces") ]] || fail 'temporary signing credentials were retained'
echo 'Release behavior tests passed.'
