#!/usr/bin/env bash
# Native build-state behavior against handwritten compiler fakes. All
# mutations, locks, and outputs live in this test's private directory.
set -euo pipefail
# shellcheck source=scripts/lib.sh
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-build-tests.XXXXXX")
cleanup() {
  local status=$?
  if ((status != 0)) && [[ -f $temporary/native.log ]]; then
    echo 'Build-test diagnostics: native.log' >&2
    cat "$temporary/native.log" >&2
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT
fixture="$temporary/project with spaces"
mkdir -p "$fixture/scripts" "$fixture/mise" "$fixture/providers/Sources" "$fixture/companion/Sources" "$fixture/companion/App/Sources" "$fixture/companion/App/Atelier.xcodeproj/xcshareddata" "$fixture/api" "$fixture/.xcodebuildmcp" "$temporary/bin"
cp "$root"/scripts/*.sh "$fixture/scripts/"
cp "$root/mise.toml" "$fixture/"
cp "$root/mise/tasks.toml" "$fixture/mise/"
cp "$root/.xcodebuildmcp/config.yaml" "$fixture/.xcodebuildmcp/"
printf 'package\n' > "$fixture/providers/Package.swift"
printf 'provider source\n' > "$fixture/providers/Sources/Host.swift"
printf 'package\n' > "$fixture/companion/Package.swift"
printf 'companion source\n' > "$fixture/companion/Sources/Runtime.swift"
printf 'intent source\n' > "$fixture/companion/App/Sources/Intents.swift"
for input in Atelier.xcodeproj/project.pbxproj Atelier.xcodeproj/xcshareddata/scheme Atelier.xcconfig Info.plist; do printf '%s\n' "$input" > "$fixture/companion/App/$input"; done
printf '#!/usr/bin/env bash\necho test-toolchain\n' > "$fixture/scripts/toolchain.sh"
export FAKE_BUILD_ROOT="$fixture" FAKE_BUILD_LOG="$temporary/compiler.log"
cat > "$temporary/bin/xcodebuildmcp" <<'COMPILER'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_BUILD_LOG"
[[ ${FAKE_COMPILE_FAIL:-false} == false ]] || exit 1
case "$1 $2" in
  'swift-package build')
    mkdir -p "$FAKE_BUILD_ROOT/providers/.build/release"
    printf 'binary\n' > "$FAKE_BUILD_ROOT/providers/.build/release/atelier-providers"
    chmod +x "$FAKE_BUILD_ROOT/providers/.build/release/atelier-providers" ;;
  'macos build')
    app="$FAKE_BUILD_ROOT/.build/companion-derived/Build/Products/Release/Atelier.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Metadata.appintents"
    printf 'companion\n' > "$app/Contents/MacOS/Atelier"
    chmod +x "$app/Contents/MacOS/Atelier"
    printf 'plist\n' > "$app/Contents/Info.plist"
    printf 'metadata\n' > "$app/Contents/Resources/Metadata.appintents/extract.actionsdata" ;;
  *) echo "unexpected fake build: $*" >&2; exit 99 ;;
esac
COMPILER
cat > "$temporary/bin/lipo" <<'LIPO'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_ARCHS:-arm64}"
LIPO
chmod +x "$temporary/bin/"*
export PATH="$temporary/bin:$PATH"
native() { "$fixture/scripts/build-native.sh" "$@" > "$temporary/native.log" 2>&1; }
# One compilation is both fake builds: the providers package and the app.
compilations() { echo $(( $(wc -l < "$FAKE_BUILD_LOG") / 2 )); }
app="$fixture/.build/native/app/Atelier.app"
: > "$FAKE_BUILD_LOG"

native
native --verify
grep -q ' --architectures arm64' "$FAKE_BUILD_LOG" || fail 'providers compilation did not restrict architectures'
grep -q 'macos build .* --arch arm64' "$FAKE_BUILD_LOG" || fail 'companion compilation did not restrict architectures'
[[ $(compilations) -eq 1 ]] || fail 'verified output recompiled'
[[ -x $app/Contents/MacOS/atelier-providers && -x $app/Contents/MacOS/Atelier ]] || fail 'the bundle does not carry both executables'
printf 'TypeScript edit\n' > "$fixture/api/index.ts"
native
[[ $(compilations) -eq 1 ]] || fail 'TypeScript edit invalidated native compilation'
"$fixture/scripts/native-cache.sh" pack > "$temporary/cache.log"
rm -rf "$fixture/.build/native/app" "$fixture/.build/native/app.json"
"$fixture/scripts/native-cache.sh" unpack >> "$temporary/cache.log"
native --verify
[[ $(compilations) -eq 1 ]] || fail 'valid cache restore recompiled'
printf 'corrupt archive\n' > "$fixture/.build/cache/app.tar.gz"
"$fixture/scripts/native-cache.sh" unpack >> "$temporary/cache.log" 2>&1
native --verify
printf 'corrupt\n' > "$app/Contents/MacOS/atelier-providers"
expect_failure native --verify
native
chmod -x "$app/Contents/MacOS/atelier-providers"
expect_failure native --verify
native
printf 'changed manifest\n' >> "$fixture/providers/Package.swift"
expect_failure native --verify
native
printf 'intent edit\n' >> "$fixture/companion/App/Sources/Intents.swift"
expect_failure native --verify
native
printf 'wrong slices\n' >> "$fixture/providers/Sources/Host.swift"
for architectures in x86_64 'x86_64 arm64'; do
  export FAKE_ARCHS="$architectures"
  expect_failure native
  expect_failure native --verify
  unset FAKE_ARCHS
done
export FAKE_COMPILE_FAIL=true
expect_failure native
unset FAKE_COMPILE_FAIL
expect_failure native --verify
native
printf '\necho changed-toolchain\n' >> "$fixture/scripts/toolchain.sh"
expect_failure native --verify
native

# Both callers must observe complete output, and only the writer compiles.
printf 'another provider change\n' >> "$fixture/providers/Sources/Host.swift"
before=$(compilations)
native & first=$!
native & second=$!
wait "$first"; wait "$second"
native --verify
[[ $(compilations) -eq $((before + 1)) ]] || fail 'concurrent callers both compiled the native output'
echo 'Build reuse and cache tests passed.'
