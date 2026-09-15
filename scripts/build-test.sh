#!/usr/bin/env bash
# Providers build-state behavior against handwritten compiler fakes. All
# mutations, locks, and outputs live in this test's private directory.
set -euo pipefail
# shellcheck source=scripts/lib.sh
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-build-tests.XXXXXX")
cleanup() {
  local status=$?
  if ((status != 0)) && [[ -f $temporary/providers.log ]]; then
    echo 'Build-test diagnostics: providers.log' >&2
    cat "$temporary/providers.log" >&2
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT
fixture="$temporary/project with spaces"
mkdir -p "$fixture/scripts" "$fixture/mise" "$fixture/providers/Sources" "$fixture/api" "$fixture/.xcodebuildmcp" "$temporary/bin"
cp "$root"/scripts/*.sh "$fixture/scripts/"
cp "$root/mise.toml" "$fixture/"
cp "$root/mise/tasks.toml" "$fixture/mise/"
cp "$root/.xcodebuildmcp/config.yaml" "$fixture/.xcodebuildmcp/"
printf 'package\n' > "$fixture/providers/Package.swift"
printf 'provider source\n' > "$fixture/providers/Sources/Host.swift"
printf '#!/usr/bin/env bash\necho test-toolchain\n' > "$fixture/scripts/toolchain.sh"
export FAKE_BUILD_ROOT="$fixture" FAKE_BUILD_LOG="$temporary/compiler.log"
cat > "$temporary/bin/xcodebuildmcp" <<'COMPILER'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_BUILD_LOG"
[[ ${FAKE_COMPILE_FAIL:-false} == false ]] || exit 1
mkdir -p "$FAKE_BUILD_ROOT/providers/.build/release"
printf 'binary\n' > "$FAKE_BUILD_ROOT/providers/.build/release/atelier-providers"
chmod +x "$FAKE_BUILD_ROOT/providers/.build/release/atelier-providers"
COMPILER
cat > "$temporary/bin/lipo" <<'LIPO'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_ARCHS:-arm64}"
LIPO
chmod +x "$temporary/bin/"*
export PATH="$temporary/bin:$PATH"
providers() { "$fixture/scripts/build-providers.sh" "$@" > "$temporary/providers.log" 2>&1; }
compilations() { wc -l < "$FAKE_BUILD_LOG" | tr -d ' '; }
: > "$FAKE_BUILD_LOG"

providers
providers --verify
grep -q ' --architectures arm64' "$FAKE_BUILD_LOG" || fail 'providers compilation did not restrict architectures'
[[ $(compilations) -eq 1 ]] || fail 'verified output recompiled'
printf 'TypeScript edit\n' > "$fixture/api/index.ts"
providers
[[ $(compilations) -eq 1 ]] || fail 'TypeScript edit invalidated native compilation'
"$fixture/scripts/native-cache.sh" pack > "$temporary/cache.log"
rm -rf "$fixture/.build/native/providers" "$fixture/.build/native/providers.json"
"$fixture/scripts/native-cache.sh" unpack >> "$temporary/cache.log"
providers --verify
[[ $(compilations) -eq 1 ]] || fail 'valid cache restore recompiled'
printf 'corrupt archive\n' > "$fixture/.build/cache/providers.tar.gz"
"$fixture/scripts/native-cache.sh" unpack >> "$temporary/cache.log" 2>&1
providers --verify
printf 'corrupt\n' > "$fixture/.build/native/providers/atelier-providers"
expect_failure providers --verify
providers
chmod -x "$fixture/.build/native/providers/atelier-providers"
expect_failure providers --verify
providers
printf 'changed manifest\n' >> "$fixture/providers/Package.swift"
expect_failure providers --verify
providers
printf 'wrong slices\n' >> "$fixture/providers/Sources/Host.swift"
for architectures in x86_64 'x86_64 arm64'; do
  export FAKE_ARCHS="$architectures"
  expect_failure providers
  expect_failure providers --verify
  unset FAKE_ARCHS
done
export FAKE_COMPILE_FAIL=true
expect_failure providers
unset FAKE_COMPILE_FAIL
expect_failure providers --verify
providers
printf '\necho changed-toolchain\n' >> "$fixture/scripts/toolchain.sh"
expect_failure providers --verify
providers

# Both callers must observe complete output, and only the writer compiles.
printf 'another provider change\n' >> "$fixture/providers/Sources/Host.swift"
before=$(compilations)
providers & first=$!
providers & second=$!
wait "$first"; wait "$second"
providers --verify
[[ $(compilations) -eq $((before + 1)) ]] || fail 'concurrent callers both compiled providers'
echo 'Build reuse and cache tests passed.'
