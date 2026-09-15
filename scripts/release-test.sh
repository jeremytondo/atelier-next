#!/usr/bin/env bash
# Exercise release invariants against disposable Git history, a fake GitHub,
# and a local tap remote. No network, real signing credentials, or release
# mutation occurs.
set -euo pipefail
# shellcheck source=scripts/lib.sh
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-release-tests.XXXXXX")
# These fixtures also run inside a real CI release wrapper. Never mark that
# outer release obsolete while exercising a fake stale branch revision.
export ATELIER_STALE_DEV_MARKER="$temporary/obsolete-fixture"
unset GITHUB_REF ATELIER_TAP_TOKEN ATELIER_TAP_REMOTE
trap 'rm -rf "$temporary"' EXIT
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
"$root/scripts/release-plan.sh" dev > "$temporary/first-dev.json"
[[ $(jq -r .marketing_version "$temporary/first-dev.json") == 0.0.1 ]] || fail 'initial dev version'
for tag in v1.9.0 v1.10.0 v20.0.0-beta.1 v01.20.0 v1.10.1-dev.20260101000000; do git -C "$repo" tag "$tag"; done
"$root/scripts/release-plan.sh" stable patch > "$temporary/patch.json"
[[ $(jq -r .tag "$temporary/patch.json") == v1.10.1 ]] || fail 'numeric SemVer sorting or prerelease filtering'
"$root/scripts/release-plan.sh" stable major > "$temporary/major.json"
[[ $(jq -r .tag "$temporary/major.json") == v2.0.0 ]] || fail 'major bump resets minor and patch'
"$root/scripts/release-plan.sh" stable minor > "$temporary/stable.json"
[[ $(jq -r .tag "$temporary/stable.json") == v1.11.0 ]] || fail 'minor bump'
"$root/scripts/release-plan.sh" dev > "$temporary/dev.json"
dev_version=$(jq -r .version "$temporary/dev.json")
[[ $dev_version == 1.10.1-dev.$(jq -r .build_number "$temporary/dev.json") ]] || fail 'dev version is the next patch plus the build'
[[ $(jq -r .tag "$temporary/dev.json") == "v$dev_version" ]] || fail 'dev tag follows the version'
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
ATELIER_RELEASE_REPO_ROOT="$temporary/shallow" expect_failure "$root/scripts/release-plan.sh" dev
ATELIER_RELEASE_REPO_ROOT="$temporary/shallow" expect_failure "$root/scripts/release-plan.sh" stable patch
expect_failure "$root/scripts/build-package.sh" --identity
jq '.tag = "v9.9.9"' "$temporary/stable.json" > "$temporary/bad-plan.json"
expect_failure "$root/scripts/validate-release-plan.sh" "$temporary/bad-plan.json"
jq '.build_number = "1"' "$temporary/stable.json" > "$temporary/bad-plan.json"
expect_failure "$root/scripts/validate-release-plan.sh" "$temporary/bad-plan.json"
jq '.tag = "dev"' "$temporary/dev.json" > "$temporary/bad-plan.json"
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
export FAKE_RELEASES='[]'
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
    *releases?per_page=100*) jq -n --argjson releases "$FAKE_RELEASES" '[$releases]' ;;
    *) echo "Unexpected fake API call: $*" >&2; exit 99 ;;
  esac
elif [[ $1 == release ]]; then
  case "$2" in create|edit|upload|delete) ;; view) echo https://example.invalid/release ;; *) exit 99 ;; esac
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

# A second checkout whose pin has an upstream release, so casks get pushed to a local tap.
released="$temporary/released checkout"
mkdir -p "$released/scripts"
cp "$root"/scripts/*.sh "$released/scripts/"
jq '.release = {tag: "0.0.13", sha256: ("a" * 64)}' "$root/hammerspoon2.json" > "$released/hammerspoon2.json"
tap="$temporary/tap.git"
git init -q --bare "$tap"
git clone -q "$tap" "$temporary/tap-seed" 2> /dev/null
git -C "$temporary/tap-seed" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m 'Tap'
git -C "$temporary/tap-seed" push -q origin HEAD
export ATELIER_TAP_REMOTE="$tap"

asset_dir="$temporary/assets"
make_assets() {
  rm -f "$asset_dir"/*
  local version asset
  version=$(jq -r .version "$temporary/$1.json")
  asset="atelier-$version-macos-arm64.tar.gz"
  printf 'packaged files\n' > "$asset_dir/$asset"
  jq --arg asset "$asset" --arg sha256 "$(shasum -a 256 "$asset_dir/$asset" | awk '{print $1}')" \
    '. + {architecture: "arm64", minimum_macos: "27.0", signing: "developer-id", notarized: true, asset: $asset, sha256: $sha256}' \
    "$temporary/$1.json" > "$asset_dir/manifest.json"
  (cd "$asset_dir" && shasum -a 256 "$asset" manifest.json > checksums.txt)
  : > "$FAKE_GH_LOG"
}
publish() { "${PUBLISH_ROOT:-$root}/scripts/publish-release.sh" "$asset_dir" > "$temporary/publish.log" 2>&1; }
tap_files() { git -C "$temporary/tap-seed" pull -q --ff-only origin HEAD 2> /dev/null && find "$temporary/tap-seed/Casks" -name '*.rb' -exec basename {} \; 2> /dev/null | sort | paste -sd' ' -; }

make_assets stable
printf 'tampered\n' >> "$asset_dir/atelier-1.11.0-macos-arm64.tar.gz"
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
! grep -Eq '^release ' "$FAKE_GH_LOG" || fail 'stale dev build changed the release'
"$root/scripts/release-current.sh" "$temporary/dev.json"
FAKE_REMOTE_COMMIT=0000000000000000000000000000000000000000 expect_failure "$root/scripts/release-current.sh" "$temporary/dev.json"
FAKE_GH_FAIL=true expect_failure "$root/scripts/release-current.sh" "$temporary/dev.json"
FAKE_GH_FAIL=true "$root/scripts/release-current.sh" "$temporary/stable.json"
GITHUB_OUTPUT="$temporary/stale-output" FAKE_REMOTE_COMMIT=0000000000000000000000000000000000000000 \
  "$root/scripts/ci-release.sh" "$temporary/dev.json"
[[ $(cat "$temporary/stale-output") == packaged=false ]] || fail 'obsolete release was not skipped before credentials/builds'

make_assets dev
FAKE_RELEASES='[{"id":1,"tag_name":"v1.10.1-dev.20260101000000","prerelease":true,"draft":false},{"id":2,"tag_name":"v1.10.0","prerelease":false,"draft":false},{"id":3,"tag_name":"v1.10.1-dev.20260102000000","prerelease":true,"draft":true}]' publish
grep -Eq "^release create v$dev_version .*--prerelease --latest=false --draft$" "$FAKE_GH_LOG" || fail 'new dev release must be a versioned prerelease'
grep -Eq "^release edit v$dev_version --draft=false --prerelease --latest=false$" "$FAKE_GH_LOG" || fail 'dev publication changed latest stable'
grep -Fxq 'release delete v1.10.1-dev.20260101000000 --yes --cleanup-tag' "$FAKE_GH_LOG" || fail 'previous dev release was not deleted'
! grep -Eq '^release delete (v1.10.0|v1.10.1-dev.20260102000000)' "$FAKE_GH_LOG" || fail 'stable or draft releases were deleted'
grep -q 'Casks not pushed' "$temporary/publish.log" || fail 'a pin without an upstream release must skip the tap'
[[ -z $(tap_files) ]] || fail 'casks were pushed without an upstream release'
make_assets dev
FAKE_RELEASES="[{\"id\":1,\"tag_name\":\"v$dev_version\",\"prerelease\":true,\"draft\":false}]" expect_failure publish
! grep -Eq '^release ' "$FAKE_GH_LOG" || fail 'an existing dev tag was overwritten'

make_assets dev
PUBLISH_ROOT=$released publish
[[ $(tap_files) == 'atelier@dev.rb hammerspoon2.rb' ]] || fail "dev casks not pushed: $(tap_files)"
grep -q "version \"$dev_version\"" "$temporary/tap-seed/Casks/atelier@dev.rb" || fail 'dev cask version'
grep -q "sha256 \"$(jq -r .sha256 "$asset_dir/manifest.json")\"" "$temporary/tap-seed/Casks/atelier@dev.rb" || fail 'dev cask checksum'
grep -q 'version "0.0.13"' "$temporary/tap-seed/Casks/hammerspoon2.rb" || fail 'hammerspoon2 cask version'
grep -q 'depends_on cask: "jeremytondo/atelier/hammerspoon2"' "$temporary/tap-seed/Casks/atelier@dev.rb" || fail 'dev cask must depend on hammerspoon2'
make_assets stable
PUBLISH_ROOT=$released publish
[[ $(tap_files) == 'atelier.rb atelier@dev.rb hammerspoon2.rb' ]] || fail "stable cask not pushed: $(tap_files)"
grep -q 'version "1.11.0"' "$temporary/tap-seed/Casks/atelier.rb" || fail 'stable cask version'
grep -Eq '^release create v1.11.0 .*--draft$' "$FAKE_GH_LOG" || fail 'stable release was not staged as a draft'
grep -Eq '^release edit v1.11.0 --draft=false --latest$' "$FAKE_GH_LOG" || fail 'stable release did not become latest'
! grep -Eq -- '--clobber|release delete|--prerelease' "$FAKE_GH_LOG" || fail 'stable publication touched other releases'
make_assets stable
ATELIER_TAP_REMOTE='' PUBLISH_ROOT=$released expect_failure publish
! grep -Eq '^release ' "$FAKE_GH_LOG" || fail 'a missing tap token must fail before any release mutation'

export FAKE_ENCODED_BRANCH='feature%2FATE-37%23candidate'
"$root/scripts/release-current.sh" "$temporary/branch.json"
make_assets branch
publish
grep -Eq '^release create v[0-9.]+-dev\.[0-9]+ .*--prerelease --latest=false --draft$' "$FAKE_GH_LOG" || fail 'branch dev was not published'
make_assets branch
FAKE_REMOTE_COMMIT=0000000000000000000000000000000000000000 publish
! grep -Eq '^release ' "$FAKE_GH_LOG" || fail 'stale branch dev changed the release'
make_assets branch
FAKE_GH_FAIL=true expect_failure publish
! grep -Eq '^release ' "$FAKE_GH_LOG" || fail 'unavailable branch changed the release'
GITHUB_OUTPUT="$temporary/stale-branch-output" FAKE_REMOTE_COMMIT=0000000000000000000000000000000000000000 \
  "$root/scripts/ci-release.sh" "$temporary/branch.json"
[[ $(cat "$temporary/stale-branch-output") == packaged=false ]] || fail 'obsolete branch was not skipped before credentials/builds'
make_assets branch-stable
publish
grep -Eq '^release create v1.10.1 .*--draft$' "$FAKE_GH_LOG" || fail 'branch stable was not published'
! grep -q 'git/ref/heads/' "$FAKE_GH_LOG" || fail 'stable must retain its selected commit'
unset FAKE_ENCODED_BRANCH

make_assets stable
FAKE_RELEASES='[{"id":1,"tag_name":"v1.11.0"}]' expect_failure publish
! grep -Eq '^release ' "$FAKE_GH_LOG" || fail 'existing stable release was modified'
make_assets stable
FAKE_TAGS='[{"ref":"refs/tags/v1.11.0"}]' expect_failure publish
! grep -Eq '^release ' "$FAKE_GH_LOG" || fail 'existing stable tag was reused'

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
