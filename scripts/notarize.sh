#!/usr/bin/env bash
# Notarize a distribution artifact without changing its signing identity.
# App bundles receive a stapled ticket; bare providers executables cannot.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# == 2 ]] || die 'usage: notarize.sh ARTIFACT LOG_DIRECTORY'
artifact=$1
logs=$2
developer_dir=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
notarytool="$developer_dir/usr/bin/notarytool"
[[ -x $notarytool ]] || die 'Select a full Xcode installation for notarization.'
if [[ -n ${ATELIER_NOTARY_PROFILE:-} ]]; then
  credentials=(--keychain-profile "$ATELIER_NOTARY_PROFILE")
else
  for name in ATELIER_APP_STORE_CONNECT_KEY_PATH ATELIER_APP_STORE_CONNECT_KEY_ID ATELIER_APP_STORE_CONNECT_ISSUER_ID; do
    [[ -n ${!name:-} ]] || die "missing notarization credential: $name"
  done
  [[ -f $ATELIER_APP_STORE_CONNECT_KEY_PATH ]] || die 'App Store Connect key file is missing.'
  credentials=(--key "$ATELIER_APP_STORE_CONNECT_KEY_PATH" --key-id "$ATELIER_APP_STORE_CONNECT_KEY_ID" --issuer "$ATELIER_APP_STORE_CONNECT_ISSUER_ID")
fi
mkdir -p "$logs"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/atelier-notarize.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
ditto -c -k --keepParent "$artifact" "$temporary/submission.zip"
if ! "$notarytool" submit "$temporary/submission.zip" "${credentials[@]}" \
    --wait --timeout 20m --output-format json > "$logs/submission.json"; then
  cat "$logs/submission.json" >&2
  die 'Notarization failed or timed out.'
fi
if [[ $(jq -r .status "$logs/submission.json") != Accepted ]]; then
  submission_id=$(jq -er .id "$logs/submission.json")
  "$notarytool" log "$submission_id" "${credentials[@]}" "$logs/log.json"
  die "Notarization rejected; see $logs/log.json"
fi
if [[ -d $artifact && $artifact == *.app ]]; then
  "$developer_dir/usr/bin/stapler" staple "$artifact"
  "$developer_dir/usr/bin/stapler" validate "$artifact"
fi
