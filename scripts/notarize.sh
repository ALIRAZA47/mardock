#!/bin/bash
# Sends a .zip or .dmg to Apple's notary service, waits for the verdict and
# staples the ticket (to the .dmg, or to the app the .zip came from).
#
#   scripts/notarize.sh <file> [app to staple, for a .zip]
#
# Credentials, either an App Store Connect API key:
#   NOTARY_API_KEY (base64 of the .p8 file), NOTARY_API_KEY_ID, NOTARY_API_ISSUER
# or an Apple ID with an app-specific password:
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
set -euo pipefail

FILE="$1"
STAPLE="${2:-$1}"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"

if [[ -n "${NOTARY_API_KEY:-}" ]]; then
  key="$TMP/notary-key.p8"
  printf '%s' "$NOTARY_API_KEY" | base64 --decode > "$key"
  trap 'rm -f "$key"' EXIT
  auth=(--key "$key" --key-id "${NOTARY_API_KEY_ID:?}" --issuer "${NOTARY_API_ISSUER:?}")
else
  auth=(--apple-id "${NOTARY_APPLE_ID:?}" --team-id "${NOTARY_TEAM_ID:?}" --password "${NOTARY_PASSWORD:?}")
fi

echo "▸ Notarizing $(basename "$FILE")"
result="$(xcrun notarytool submit "$FILE" "${auth[@]}" --wait --timeout 45m --output-format json)"
echo "$result"
status="$(printf '%s' "$result" | plutil -extract status raw -o - - 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
  id="$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || true)"
  [[ -n "$id" ]] && xcrun notarytool log "$id" "${auth[@]}" || true
  echo "error: notarization finished with status '${status:-unknown}'" >&2
  exit 1
fi

xcrun stapler staple "$STAPLE"
xcrun stapler validate "$STAPLE"
echo "✓ Notarized and stapled $(basename "$STAPLE")"
