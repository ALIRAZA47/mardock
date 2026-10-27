#!/bin/bash
# CI only (release workflow): puts the Developer ID certificate into a
# throwaway keychain for codesign. The runner is discarded afterwards, and
# the keychain is deleted at the end of the job anyway.
#
# Environment: MACOS_CERTIFICATE (base64 of a .p12 export of the
# "Developer ID Application" certificate and its private key) and
# MACOS_CERTIFICATE_PASSWORD (the password chosen when exporting it).
set -euo pipefail

: "${MACOS_CERTIFICATE:?}" "${MACOS_CERTIFICATE_PASSWORD:?}" "${RUNNER_TEMP:?}"

KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
CERT="$RUNNER_TEMP/certificate.p12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

printf '%s' "$MACOS_CERTIFICATE" | base64 --decode > "$CERT"
security import "$CERT" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
rm -f "$CERT"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# Search the new keychain first, then the usual ones.
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
echo "Signing identities:"
security find-identity -v -p codesigning "$KEYCHAIN" | sed 's/^/  /'
echo "keychain=$KEYCHAIN" >> "${GITHUB_OUTPUT:-/dev/null}"
