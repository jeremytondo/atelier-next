#!/usr/bin/env bash
# Run one command on a GitHub Actions runner with the release credentials in
# reach, and take them away again however the command ends: the Developer ID
# certificate in a keychain made for the purpose, and the notarization key in
# a file, named to the command by ATELIER_APP_STORE_CONNECT_KEY_PATH.
#
# usage: scripts/with-signing.sh COMMAND [ARGUMENT...]
set -euo pipefail
umask 077
die() {
  echo "with-signing.sh: $*" >&2
  exit 1
}
[[ ${GITHUB_ACTIONS:-} == true && -d ${RUNNER_TEMP:-} && $# -gt 0 ]] ||
  die 'this wraps a command on a GitHub Actions runner'
for name in ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64 ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD \
  ATELIER_APP_STORE_CONNECT_KEY_BASE64 ATELIER_APP_STORE_CONNECT_KEY_ID ATELIER_APP_STORE_CONNECT_ISSUER_ID; do
  [[ -n ${!name:-} ]] || die "missing release credential: $name"
done

folder=$(mktemp -d "$RUNNER_TEMP/atelier-signing.XXXXXX")
keychain="$folder/release.keychain-db"
before=()
while IFS= read -r entry; do
  before+=("$entry")
done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*$/\1/')
cleanup() {
  if [[ ${#before[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${before[@]}" >/dev/null 2>&1 || true
  fi
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$folder"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s' "$ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64" | base64 --decode >"$folder/developer-id.p12"
printf '%s' "$ATELIER_APP_STORE_CONNECT_KEY_BASE64" | base64 --decode >"$folder/AuthKey.p8"
[[ -s $folder/AuthKey.p8 ]] || die 'the notarization key is empty'
password=$(uuidgen)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$folder/developer-id.p12" -k "$keychain" \
  -P "$ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" ${before[@]+"${before[@]}"}
rm "$folder/developer-id.p12"
unset ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64 ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD ATELIER_APP_STORE_CONNECT_KEY_BASE64
security find-identity -v -p codesigning "$keychain" | grep -q 'Developer ID Application' ||
  die 'the certificate is not a valid Developer ID Application identity'
export ATELIER_APP_STORE_CONNECT_KEY_PATH="$folder/AuthKey.p8"
"$@"
