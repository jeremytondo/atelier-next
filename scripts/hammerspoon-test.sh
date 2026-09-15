#!/usr/bin/env bash
# Exercise snapshot resolution with fake build/signing tools and reference
# updates with local Git repositories. No app launches or real user state.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-hs2-tests.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
fixture="$temporary/fixture"
mkdir -p "$fixture/scripts" "$temporary/bin"
cp "$root/scripts/"*.sh "$fixture/scripts/"
cp -R "$root/scripts/hs2" "$fixture/scripts/"
cp -R "$root/.xcodebuildmcp" "$fixture/"
cp "$root/hammerspoon2.json" "$fixture/"
# Tests remain valid when the real pin later names an upstream release.
jq '.release = null' "$fixture/hammerspoon2.json" > "$temporary/pin.json"
mv "$temporary/pin.json" "$fixture/hammerspoon2.json"
export FAKE_PIN="$fixture/hammerspoon2.json" FAKE_BUILD_LOG="$temporary/build.log"
export FAKE_RELEASES='[]' FAKE_GH_FAIL=false FAKE_VERIFY_FAIL=false
export FAKE_PUBLISHED="$temporary/published" FAKE_TOOLCHAIN=xcode-one
export ATELIER_SIGN_IDENTITY=1111111111111111111111111111111111111111
export GH_REPO=jeremytondo/atelier-next GITHUB_REPOSITORY=jeremytondo/atelier-next
cat > "$fixture/scripts/build-hammerspoon.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --distribution ]]
echo build >> "$FAKE_BUILD_LOG"
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/.build/native/hs2/Hammerspoon 2.app/Contents"
jq '{CFBundleVersion: .build}' "$FAKE_PIN" > "$root/.build/native/hs2/Hammerspoon 2.app/Contents/Info.plist"
FAKE
cat > "$temporary/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ $FAKE_GH_FAIL == false ]] || exit 99
if [[ $1 == api ]]; then
  case "$*" in
    *commits/*) if [[ -n ${FAKE_UPSTREAM_REVISION:-} ]]; then echo "$FAKE_UPSTREAM_REVISION"; else jq -r .revision "$FAKE_PIN"; fi ;;
    *releases?per_page=100*) jq -n --argjson releases "$FAKE_RELEASES" '[$releases]' ;;
    *) exit 99 ;;
  esac
elif [[ $1 == release && $2 == download ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ $1 == --dir ]]; then destination=$2; shift; fi
    shift
  done
  cp "$FAKE_PUBLISHED/manifest.json" "$FAKE_PUBLISHED/Hammerspoon.2.zip" "$destination/"
else
  exit 99
fi
FAKE
cat > "$temporary/bin/plutil" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == -extract ]]; then
  jq -r .CFBundleVersion "${@: -1}"
else
  echo "$FAKE_TOOLCHAIN"
fi
FAKE
cat > "$temporary/bin/ditto" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == -c ]]; then
  source=${@: -2:1}; destination=${@: -1}
  tar -cf "$destination" -C "$(dirname "$source")" "$(basename "$source")"
elif [[ $1 == -x ]]; then
  mkdir -p "$4"
  tar -xf "$3" -C "$4"
else
  exit 99
fi
FAKE
cat > "$temporary/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
cp "$FAKE_PUBLISHED/Hammerspoon.2.zip" "${@: -1}"
FAKE
printf '#!/usr/bin/env bash\necho 2.6.2\n' > "$temporary/bin/xcodebuildmcp"
# shellcheck disable=SC2016 # the fake reads the test setting when invoked
printf '#!/usr/bin/env bash\n[[ $FAKE_VERIFY_FAIL == false ]]\n' > "$temporary/bin/codesign"
cp "$temporary/bin/codesign" "$temporary/bin/spctl"
chmod +x "$temporary/bin/"* "$fixture/scripts/"*.sh
export PATH="$temporary/bin:$PATH" DEVELOPER_DIR="$temporary/Xcode/Contents/Developer"
: > "$FAKE_BUILD_LOG"
resolve() { "$fixture/scripts/resolve-hammerspoon.sh" "$temporary/resolved"; }
inputs() { "$fixture/scripts/hammerspoon-inputs.sh"; }

before=$(inputs)
echo 'Atelier documentation' > "$fixture/README.md"
[[ $(inputs) == "$before" ]] || fail 'unrelated changes invalidated HS2'
after=$(FAKE_TOOLCHAIN=xcode-two inputs)
[[ $after != "$before" ]] || fail 'toolchain change did not invalidate HS2'
after=$(ATELIER_SIGN_IDENTITY=2222222222222222222222222222222222222222 inputs)
[[ $after != "$before" ]] || fail 'signing change did not invalidate HS2'
resolve
[[ $(wc -l < "$FAKE_BUILD_LOG" | tr -d ' ') == 1 ]] || fail 'first snapshot did not build once'
cp -R "$temporary/resolved" "$FAKE_PUBLISHED"
tag=$(jq -r .tag "$FAKE_PUBLISHED/manifest.json")
export FAKE_RELEASES="[{\"id\":1,\"tag_name\":\"$tag\",\"draft\":false}]"
resolve
[[ $(wc -l < "$FAKE_BUILD_LOG" | tr -d ' ') == 1 ]] || fail 'published snapshot was rebuilt'
FAKE_GH_FAIL=true expect_failure resolve
FAKE_VERIFY_FAIL=true expect_failure resolve
FAKE_RELEASES="[{\"id\":1,\"tag_name\":\"$tag\",\"draft\":true}]" expect_failure resolve
cp "$FAKE_PUBLISHED/Hammerspoon.2.zip" "$temporary/good.zip"
printf corruption >> "$FAKE_PUBLISHED/Hammerspoon.2.zip"
expect_failure resolve
[[ $(wc -l < "$FAKE_BUILD_LOG" | tr -d ' ') == 1 ]] || fail 'failed reuse rebuilt a published snapshot'
cp "$temporary/good.zip" "$FAKE_PUBLISHED/Hammerspoon.2.zip"
echo '# changed build recipe' >> "$fixture/scripts/build-hammerspoon.sh"
resolve
[[ $(wc -l < "$FAKE_BUILD_LOG" | tr -d ' ') == 2 ]] || fail 'recipe change did not build a new snapshot'
[[ $(jq -r .tag "$temporary/resolved/manifest.json") != "$tag" ]] || fail 'new build reused old download identity'

# Official release selection skips our compiler and validates the app build.
jq --arg sha "$(shasum -a 256 "$FAKE_PUBLISHED/Hammerspoon.2.zip" | awk '{print $1}')" \
  '.release = {tag: "0.0.13", sha256: $sha}' "$FAKE_PIN" > "$temporary/pin.json"
mv "$temporary/pin.json" "$FAKE_PIN"
resolve
[[ $(jq -r .kind "$temporary/resolved/manifest.json") == upstream ]] || fail 'official release not selected'
[[ $(wc -l < "$FAKE_BUILD_LOG" | tr -d ' ') == 2 ]] || fail 'official release compiled HS2'
FAKE_UPSTREAM_REVISION=0000000000000000000000000000000000000000 expect_failure resolve
jq '.build = "999"' "$FAKE_PIN" > "$temporary/pin.json"
mv "$temporary/pin.json" "$FAKE_PIN"
expect_failure resolve

# Shared notarization only staples accepted app bundles; rejection stops before
# an artifact can be published. Bare executables use the same submission path.
mkdir -p "$DEVELOPER_DIR/usr/bin"
export FAKE_NOTARIZATION=Accepted FAKE_STAPLE_LOG="$temporary/stapler.log"
export ATELIER_NOTARY_PROFILE=fixture
cat > "$DEVELOPER_DIR/usr/bin/notarytool" <<'FAKE'
#!/usr/bin/env bash
if [[ $1 == submit ]]; then
  printf '{"status":"%s","id":"fixture"}\n' "$FAKE_NOTARIZATION"
elif [[ $1 == log ]]; then
  echo rejected > "${@: -1}"
else
  exit 99
fi
FAKE
cat > "$DEVELOPER_DIR/usr/bin/stapler" <<'FAKE'
#!/usr/bin/env bash
echo "$1" >> "$FAKE_STAPLE_LOG"
FAKE
chmod +x "$DEVELOPER_DIR/usr/bin/"*
notarize() { "$root/scripts/notarize.sh" "$fixture/.build/native/hs2/Hammerspoon 2.app" "$temporary/notarization"; }
notarize
[[ $(cat "$FAKE_STAPLE_LOG") == $'staple\nvalidate' ]] || fail 'accepted app was not stapled and validated'
: > "$FAKE_STAPLE_LOG"
FAKE_NOTARIZATION=Invalid expect_failure notarize
[[ ! -s $FAKE_STAPLE_LOG && -s $temporary/notarization/log.json ]] || fail 'rejected app was stapled or lost rejection details'
"$root/scripts/notarize.sh" "$fixture/scripts/build-hammerspoon.sh" "$temporary/bare-notarization"
[[ ! -s $FAKE_STAPLE_LOG ]] || fail 'bare executable was stapled'

# References use real Git, scoped to disposable repositories.
unset DEVELOPER_DIR
upstream="$temporary/upstream"
git init -q --initial-branch=main "$upstream"
git -C "$upstream" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m first
first=$(git -C "$upstream" rev-parse HEAD)
git -C "$upstream" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m second
second=$(git -C "$upstream" rev-parse HEAD)
sed "s|https://github.com/cmsj/Hammerspoon2.git|file://$upstream|" "$root/scripts/refs.sh" > "$fixture/scripts/refs.sh"
set_pin() {
  jq --arg revision "$1" '.revision = $revision' "$FAKE_PIN" > "$temporary/pin.json"
  mv "$temporary/pin.json" "$FAKE_PIN"
}
refs() { "$fixture/scripts/refs.sh" "$@"; }
set_pin "$first"
refs status
[[ ! -e $fixture/repos ]] || fail 'status created a checkout'
refs fetch
checkout="$fixture/repos/hammerspoon2"
[[ $(git -C "$checkout" rev-parse HEAD) == "$first" ]] || fail 'reference followed main instead of pin'
set_pin "$second"
refs fetch
[[ $(git -C "$checkout" rev-parse HEAD) == "$first" ]] || fail 'fetch moved an existing checkout'
echo mine > "$checkout/local-file"
expect_failure refs update
[[ $(cat "$checkout/local-file") == mine ]] || fail 'reference update lost local edits'
rm "$checkout/local-file"
refs update
[[ $(git -C "$checkout" rev-parse HEAD) == "$second" ]] || fail 'reference did not update to pin'
git -C "$checkout" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m local
local_commit=$(git -C "$checkout" rev-parse HEAD)
expect_failure refs update
[[ $(git -C "$checkout" rev-parse HEAD) == "$local_commit" ]] || fail 'reference update lost local commit'
mv "$checkout" "$temporary/saved-reference"
git clone -q --depth 1 --branch main "file://$upstream" "$checkout"
set_pin "$first"
refs update
[[ $(git -C "$checkout" rev-parse HEAD) == "$first" && -z $(git -C "$checkout" branch --show-current) ]] || fail 'old main checkout did not migrate to pin'
echo 'HS2 snapshot and reference tests passed.'
