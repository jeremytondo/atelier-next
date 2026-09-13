#!/usr/bin/env bash
# Scope imported credentials and keychain changes to one hosted CI command.
set -euo pipefail
umask 077
[[ ${GITHUB_ACTIONS:-} == true && -d ${RUNNER_TEMP:-} && $# -gt 0 ]] || {
  echo 'ci-signing.sh must wrap a command on a GitHub Actions runner' >&2; exit 1;
}
for name in ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64 ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD \
  ATELIER_APP_STORE_CONNECT_KEY_BASE64 ATELIER_APP_STORE_CONNECT_KEY_ID ATELIER_APP_STORE_CONNECT_ISSUER_ID; do
  [[ -n ${!name:-} ]] || { echo "missing release credential: $name" >&2; exit 1; }
done

credential_dir=$(mktemp -d "$RUNNER_TEMP/atelier-signing.XXXXXX")
keychain="$credential_dir/release.keychain-db"
original_keychains=()
security list-keychains -d user > "$credential_dir/keychains"
while IFS= read -r entry; do
  original_keychains+=("$entry")
done < <(sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*$/\1/' "$credential_dir/keychains")
cleanup() {
  if [[ ${#original_keychains[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${original_keychains[@]}" > /dev/null 2>&1 || true
  fi
  security delete-keychain "$keychain" > /dev/null 2>&1 || true
  rm -rf "$credential_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s' "$ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64" | base64 --decode > "$credential_dir/developer-id.p12"
printf '%s' "$ATELIER_APP_STORE_CONNECT_KEY_BASE64" | base64 --decode > "$credential_dir/AuthKey.p8"
keychain_password=$(uuidgen)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$credential_dir/developer-id.p12" -k "$keychain" \
  -P "$ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain" ${original_keychains[@]+"${original_keychains[@]}"}
rm "$credential_dir/developer-id.p12"
unset ATELIER_DEVELOPER_ID_CERTIFICATE_BASE64 ATELIER_DEVELOPER_ID_CERTIFICATE_PASSWORD ATELIER_APP_STORE_CONNECT_KEY_BASE64
export ATELIER_SIGN_KEYCHAIN="$keychain"
export ATELIER_APP_STORE_CONNECT_KEY_PATH="$credential_dir/AuthKey.p8"
"$@"
