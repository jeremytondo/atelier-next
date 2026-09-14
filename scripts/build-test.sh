#!/usr/bin/env bash
# Build-state behavior against a tiny archive and handwritten compiler fakes.
# All mutations, locks, and outputs live in this test's private directory.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-build-tests.XXXXXX")
cleanup() {
  local status=$? log
  if ((status != 0)); then
    for log in "$temporary/prepare.log" "$temporary/host.log" "$temporary/helpers.log"; do
      if [[ -f $log ]]; then
        echo "Build-test diagnostics: ${log##*/}" >&2
        cat "$log" >&2
      fi
    done
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT
fixture="$temporary/project with spaces"
mkdir -p "$fixture/scripts" "$fixture/mise" "$fixture/App/Hammerspoon" "$fixture/App/Sources" "$fixture/App/Resources" "$fixture/.build/downloads" "$fixture/.xcodebuildmcp" "$temporary/bin"
cp "$root"/scripts/*.sh "$fixture/scripts/"
cp "$root/mise.toml" "$fixture/"
cp "$root/mise/tasks.toml" "$fixture/mise/"
cp "$root/.xcodebuildmcp/config.yaml" "$fixture/.xcodebuildmcp/"
printf 'package\n' > "$fixture/App/Package.swift"
printf 'helper source\n' > "$fixture/App/Sources/helper.swift"
printf '#!/usr/bin/env bash\necho test-toolchain\n' > "$fixture/scripts/toolchain.sh"
upstream="$temporary/upstream/hs2"
mkdir -p "$upstream/Hammerspoon 2/Lifecycle" "$upstream/Hammerspoon 2/Managers" "$upstream/Hammerspoon 2/Windows/Settings" "$upstream/Hammerspoon 2/Modules/hs.ipc" "$upstream/hs2"
for path in Lifecycle/Hammerspoon_2App.swift Managers/ManagerManager.swift Managers/SettingsManager.swift Windows/OnboardingView.swift; do
  printf 'upstream shell\n' > "$upstream/Hammerspoon 2/$path"
done
mkdir -p "$fixture/App/Hammerspoon/Shell" "$fixture/App/Hammerspoon/ShellCore" "$fixture/App/Hammerspoon/IPC"
printf '@main\n' > "$fixture/App/Hammerspoon/Shell/AtelierApp.swift"
printf 'core\n' > "$fixture/App/Hammerspoon/ShellCore/Core.swift"
printf 'transport\n' > "$fixture/App/Hammerspoon/IPC/Transport.swift"
printf 'before\n' > "$upstream/sample"
printf 'license\n' > "$upstream/LICENSE"
revision=1111111111111111111111111111111111111111
archive="$fixture/.build/downloads/hs2-$revision.tar.gz"
tar -czf "$archive" -C "$temporary/upstream" hs2
checksum=$(shasum -a 256 "$archive" | awk '{print $1}')
jq -n --arg revision "$revision" --arg sha256 "$checksum" '{revision: $revision, sha256: $sha256}' > "$fixture/App/Hammerspoon/upstream.json"
printf 'host\n' > "$fixture/App/Hammerspoon/Shell/AtelierHost.swift"
printf 'scheme\n' > "$fixture/App/Hammerspoon/Atelier.xcscheme"
cat > "$fixture/App/Hammerspoon/atelier.patch" <<'PATCH'
--- a/sample
+++ b/sample
@@ -1 +1 @@
-before
+after
PATCH
export FAKE_BUILD_ROOT="$fixture" FAKE_BUILD_LOG="$temporary/compiler.log"
cat > "$temporary/bin/xcodebuildmcp" <<'COMPILER'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_BUILD_LOG"
[[ ${FAKE_COMPILE_FAIL:-false} == false ]] || exit 1
if [[ $1 == macos ]]; then
  output="$FAKE_BUILD_ROOT/.build/hs2-derived/Build/Products/Release/Hammerspoon 2.app/Contents"
  mkdir -p "$output/MacOS" "$output/Resources" "$output/XPCServices/HammerspoonOSAScriptHelper.xpc/Contents/MacOS"
  for binary in 'MacOS/Hammerspoon 2' MacOS/hs2 XPCServices/HammerspoonOSAScriptHelper.xpc/Contents/MacOS/HammerspoonOSAScriptHelper; do
    printf 'binary\n' > "$output/$binary"; chmod +x "$output/$binary"
  done
  printf 'plist\n' > "$output/Info.plist"
  printf 'resource\n' > "$output/Resources/engine.js"
  for dependency in AXSwift javascript-core-extras swift-commandlinekit xctest-dynamic-overlay swift-issue-reporting Sparkle; do
    directory="$FAKE_BUILD_ROOT/.build/hs2-derived/SourcePackages/checkouts/$dependency"
    mkdir -p "$directory"; printf 'license\n' > "$directory/LICENSE"
  done
else
  mkdir -p "$FAKE_BUILD_ROOT/App/.build/release"
  for binary in atelier-engine atelier-tools; do
    printf 'binary\n' > "$FAKE_BUILD_ROOT/App/.build/release/$binary"
    chmod +x "$FAKE_BUILD_ROOT/App/.build/release/$binary"
  done
fi
COMPILER
cat > "$temporary/bin/ditto" <<'DITTO'
#!/usr/bin/env bash
set -euo pipefail
if [[ -d $1 ]]; then mkdir -p "$2"; cp -R "$1/." "$2/"; else cp "$1" "$2"; fi
DITTO
cat > "$temporary/bin/lipo" <<'LIPO'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_ARCHS:-arm64}"
LIPO
chmod +x "$temporary/bin/"*
export PATH="$temporary/bin:$PATH"
prepare() { "$fixture/scripts/prepare-hammerspoon.sh" > "$temporary/prepare.log" 2>&1; }
host() { "$fixture/scripts/build-hammerspoon.sh" "$@" > "$temporary/host.log" 2>&1; }
helpers() { "$fixture/scripts/build-helpers.sh" "$@" > "$temporary/helpers.log" 2>&1; }
prepare
[[ $(cat "$fixture/.build/hammerspoon2/sample") == after ]] || fail 'patch not applied'
[[ ! -e "$fixture/.build/hammerspoon2/Hammerspoon 2/Lifecycle/Hammerspoon_2App.swift" ]] || fail 'upstream entry point retained'
[[ ! -e "$fixture/.build/hammerspoon2/Hammerspoon 2/Windows/Settings" ]] || fail 'upstream Settings retained'
cmp "$fixture/.build/hammerspoon2/Hammerspoon 2/Modules/hs.ipc/Transport.swift" "$fixture/.build/hammerspoon2/hs2/Transport.swift" || fail 'IPC targets use different transports'
host_source="$fixture/.build/hammerspoon2/Hammerspoon 2/Atelier/AtelierHost.swift"
touch -t 200101010000 "$host_source"
before=$(perl -e 'print((stat($ARGV[0]))[9])' "$host_source")
prepare
[[ $(perl -e 'print((stat($ARGV[0]))[9])' "$host_source") == "$before" ]] || fail 'matching preparation rewrote source timestamps'
printf 'corrupt\n' > "$host_source"
prepare
[[ $(cat "$host_source") == host ]] || fail 'corrupt preparation reused'
rm "$fixture/.build/hammerspoon2/sample"
prepare
[[ $(cat "$fixture/.build/hammerspoon2/sample") == after ]] || fail 'missing preparation reused'

# A failed staged replacement leaves the previous source usable, but does not
# certify it against changed inputs. A retry must finish preparation.
cp "$fixture/App/Hammerspoon/atelier.patch" "$temporary/good.patch"
printf 'invalid patch\n' > "$fixture/App/Hammerspoon/atelier.patch"
expect_failure prepare
[[ $(cat "$fixture/.build/hammerspoon2/sample") == after ]] || fail 'failed preparation damaged the prior tree'
cp "$temporary/good.patch" "$fixture/App/Hammerspoon/atelier.patch"
mv "$fixture/.build/hammerspoon2" "$fixture/.build/hammerspoon2.previous"
prepare
[[ ! -d $fixture/.build/hammerspoon2.previous ]] || fail 'interrupted replacement not recovered'
rm "$fixture/.build/prepared.json"
cp "$archive" "$temporary/good.tar.gz"
printf 'corrupt archive\n' > "$archive"
expect_failure prepare
cp "$temporary/good.tar.gz" "$archive"
prepare

host; helpers
host --verify; helpers --verify
grep -q ' ARCHS=arm64 ' "$FAKE_BUILD_LOG" || fail 'host compilation did not restrict Release architectures'
[[ $(wc -l < "$FAKE_BUILD_LOG") -eq 2 ]] || fail 'verified outputs recompiled'
printf 'JS-only edit\n' > "$fixture/App/Resources/runtime.js"
host; helpers
[[ $(wc -l < "$FAKE_BUILD_LOG") -eq 2 ]] || fail 'JS edit invalidated native compilation'
"$fixture/scripts/native-cache.sh" pack host > "$temporary/cache.log"
rm -rf "$fixture/.build/native/host" "$fixture/.build/native/host.json"
"$fixture/scripts/native-cache.sh" unpack host >> "$temporary/cache.log"
host --verify
[[ $(wc -l < "$FAKE_BUILD_LOG") -eq 2 ]] || fail 'valid cache restore recompiled'
printf 'corrupt archive\n' > "$fixture/.build/cache/host.tar.gz"
"$fixture/scripts/native-cache.sh" unpack host >> "$temporary/cache.log" 2>&1
host --verify
printf 'corrupt\n' > "$fixture/.build/native/host/Hammerspoon 2.app/Contents/Resources/engine.js"
expect_failure host --verify
host
rm "$fixture/.build/native/host/Licenses/AXSwift.txt"
expect_failure host --verify
host
rm "$fixture/.build/native/host/Hammerspoon 2.app/Contents/XPCServices/HammerspoonOSAScriptHelper.xpc/Contents/MacOS/HammerspoonOSAScriptHelper"
expect_failure host --verify
host
chmod -x "$fixture/.build/native/helpers/atelier-engine"
expect_failure helpers --verify
helpers
printf 'changed manifest\n' >> "$fixture/App/Package.swift"
expect_failure helpers --verify
helpers
printf 'changed host\n' >> "$fixture/App/Hammerspoon/Shell/AtelierHost.swift"
expect_failure host --verify
for architectures in x86_64 'x86_64 arm64'; do
  FAKE_ARCHS="$architectures" expect_failure host
  expect_failure host --verify
done
FAKE_COMPILE_FAIL=true expect_failure host
expect_failure host --verify
host
printf '\necho changed-toolchain\n' >> "$fixture/scripts/toolchain.sh"
expect_failure host --verify
expect_failure helpers --verify
host; helpers
printf '\n' >> "$fixture/App/Hammerspoon/atelier.patch"
expect_failure host --verify
host
jq '.revision = "2222222222222222222222222222222222222222"' "$fixture/App/Hammerspoon/upstream.json" > "$temporary/new-pin"
mv "$temporary/new-pin" "$fixture/App/Hammerspoon/upstream.json"
expect_failure host --verify

# Both callers must observe complete output, and only the writer compiles.
printf 'another helper change\n' >> "$fixture/App/Sources/helper.swift"
compilations_before=$(wc -l < "$FAKE_BUILD_LOG")
helpers & first=$!
helpers & second=$!
wait "$first"; wait "$second"
helpers --verify
[[ $(wc -l < "$FAKE_BUILD_LOG") -eq $((compilations_before + 1)) ]] || fail 'concurrent callers both compiled helpers'
echo 'Build reuse, preparation, and cache tests passed.'
