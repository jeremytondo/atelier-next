#!/usr/bin/env bash
# Assemble the package the atelier cask installs: compiled TypeScript, type
# declarations, the seed config, the atelier command, and the signed providers
# binary. Distribution is fail-closed: Developer ID, a secure timestamp, and
# accepted notarization must all pass. A bare executable cannot carry a
# stapled ticket, so Gatekeeper checks the notarization online.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$root"

usage() {
  cat <<'USAGE'
usage: mise run build [--install] [--skip-build] [--identity NAME_OR_HASH] [--output-dir DIR]
       mise run release:package PLAN.json [--skip-build] [--output-dir DIR]

Local builds default to Apple Development signing, then ad-hoc.
Release plans require Developer ID signing and notarization credentials.
--skip-build requires a matching providers receipt.
--install copies the package into the Homebrew prefix in place of the cask's copy.
USAGE
}
arguments=("$@")
install_package=false; skip_build=false
identity=${ATELIER_SIGN_IDENTITY:-}
plan=''; output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) install_package=true; shift ;;
    --skip-build) skip_build=true; shift ;;
    --identity|--release-plan|--output-dir)
      [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "missing value for $1"
      case "$1" in
        --identity) identity=$2 ;;
        --release-plan) plan=$2 ;;
        --output-dir) output=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die 'Atelier currently targets Apple silicon Macs.'

channel=local
commit=$("$root/scripts/source-commit.sh")
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_number=${built_at//[-:TZ]/}
version="local.$build_number+${commit:0:8}"
if [[ -n $plan ]]; then
  [[ $install_package == false ]] || die '--install cannot be used for releases'
  checkout_commit=$commit
  load_release_plan "$plan"
  [[ $commit == "$checkout_commit" ]] || die 'release plan does not match this checkout'
fi
output=${output:-$root/dist}
mkdir -p "$output"
output=$(cd "$output" && pwd -P)
if [[ ${ATELIER_PACKAGE_LOCKED:-} != "$output" ]]; then
  exec "$root/scripts/with-lock.sh" "$output/.atelier-package.lock" \
    env ATELIER_PACKAGE_LOCKED="$output" "$0" ${arguments[@]+"${arguments[@]}"}
fi
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-package.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

signing_keychain=()
if [[ -n ${ATELIER_SIGN_KEYCHAIN:-} ]]; then signing_keychain=("$ATELIER_SIGN_KEYCHAIN"); fi
security find-identity -v -p codesigning ${signing_keychain[@]+"${signing_keychain[@]}"} > "$temporary/identities"
if [[ $channel == local ]]; then
  if [[ -z $identity ]]; then
    identity=$(signing_identity 'Apple Development' "$temporary/identities")
    identity=${identity:--}
  fi
  timestamp=--timestamp=none
else
  if [[ -z $identity ]]; then
    identity=$(signing_identity 'Developer ID Application' "$temporary/identities")
  fi
  if [[ -z $identity || $identity == - ]]; then
    echo 'Signing identities (including invalid identities):' >&2
    security find-identity -p codesigning ${signing_keychain[@]+"${signing_keychain[@]}"} >&2 || true
    die 'No valid Developer ID Application identity is available. The .p12 must include its certificate and matching private key, with a valid Apple certificate chain.'
  fi
  awk -v identity="$identity" '
    /"Developer ID Application:/ { name=$0; sub(/^[^"]*"/, "", name); sub(/".*$/, "", name);
      if ($2 == identity || name == identity) found=1 }
    END { exit !found }
  ' "$temporary/identities" || die 'Distribution requires a valid Developer ID Application identity.'
  timestamp=--timestamp
fi

if [[ $skip_build == false ]]; then
  "$root/scripts/build-providers.sh"
fi
# Copy the verified binary while holding the producer's lock.
mkdir "$temporary/native"
# shellcheck disable=SC2016  # the quoted command receives its paths as arguments
"$root/scripts/with-lock.sh" "$root/.build/locks/providers" sh -c \
  '"$1/scripts/build-providers.sh" --locked --verify && cp "$1/.build/native/providers/atelier-providers" "$2/native/"' \
  sh "$root" "$temporary"
providers="$temporary/native/atelier-providers"
[[ $(lipo -archs "$providers") == arm64 ]] || die 'expected an arm64 providers executable'

if [[ $channel != local ]]; then
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then "$root/scripts/release-current.sh" "$plan"; fi
  export ATELIER_SIGN_IDENTITY="$identity"
  ATELIER_NOTARIZATION_DIR="$output/notarization" "$root/scripts/resolve-hammerspoon.sh" "$output/hammerspoon2"
fi

stage="$temporary/package"
share="$stage/share/atelier"
mkdir -p "$share" "$stage/bin"
"$root/scripts/fetch-types.sh"
tsc -p tsconfig.json --outDir "$share"
cp "$root/.build/types/hammerspoon.d.ts" "$share/hammerspoon.d.ts"
cp "$root/hammerspoon2.json" "$share/hammerspoon2.json"
cp "$root/install/init.js" "$share/init.js"
cp "$providers" "$share/atelier-providers"
install -m 755 "$root/cli/atelier" "$stage/bin/atelier"
jq -n --arg version "$version" --arg channel "$channel" --arg commit "$commit" --arg built_at "$built_at" \
  --slurpfile pin "$root/hammerspoon2.json" \
  '{version: $version, channel: $channel, commit: $commit, built_at: $built_at, hammerspoon2: $pin[0]}' > "$share/version.json"
# Credential setup uses umask 077; installed files still need to be readable
# and executable for every user on the Mac.
umask 022
chmod -R u=rwX,go=rX "$stage"
codesign --force --sign "$identity" --options runtime "$timestamp" "$share/atelier-providers"
codesign --verify --strict --verbose=2 "$share/atelier-providers"

asset="atelier-$version-macos-arm64.tar.gz"
if [[ $channel != local ]]; then
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then "$root/scripts/release-current.sh" "$plan"; fi
  "$root/scripts/notarize.sh" "$share/atelier-providers" "$output/notarization/providers"
fi
# Nothing replaces the last package until signing and notarization have passed.
COPYFILE_DISABLE=1 tar -czf "$temporary/$asset" -C "$stage" bin share
rm -rf "$output/package"
ditto "$stage" "$output/package"
mv "$temporary/$asset" "$output/$asset"
if [[ $channel != local ]]; then
  sha256=$(shasum -a 256 "$output/$asset" | awk '{print $1}')
  jq --slurpfile hs2 "$root/hammerspoon2.json" --slurpfile artifact "$output/hammerspoon2/manifest.json" \
    --arg asset "$asset" --arg sha256 "$sha256" \
    '. + {architecture: "arm64", minimum_macos: "27.0", signing: "developer-id", notarized: true,
    hammerspoon2: $hs2[0], hammerspoon2_artifact: $artifact[0], asset: $asset, sha256: $sha256}' "$plan" > "$output/manifest.json"
  (cd "$output" && shasum -a 256 "$asset" manifest.json > checksums.txt)
fi

if [[ $install_package == true ]]; then
  prefix=$(brew --prefix 2>/dev/null || echo /opt/homebrew)
  mkdir -p "$prefix/share" "$prefix/bin"
  rm -rf "$prefix/share/atelier"
  ditto "$stage/share/atelier" "$prefix/share/atelier"
  install -m 755 "$stage/bin/atelier" "$prefix/bin/atelier"
  printf 'Installed: %s/share/atelier and %s/bin/atelier\n' "$prefix" "$prefix"
  echo 'Choose Reload Config in Hammerspoon 2 to load it. New Macs also need atelier install once.'
fi
printf 'Package: %s/%s\nVersion: %s (%s)\n' "$output" "$asset" "$version" "$channel"
