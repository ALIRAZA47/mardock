#!/bin/bash
# CI only: tries to allow the self-test build Accessibility and Screen
# Recording, the way switching MarDock on in System Settings would, so the
# self-test can exercise the extras that need them. That means writing to
# the system TCC database, which only works where System Integrity
# Protection is off (throwaway CI runners); anywhere else it reports why and
# changes nothing. Never run this on your own Mac.
set -uo pipefail

APP="${1:-build/selftest/MarDock.app}"
DB="/Library/Application Support/com.apple.TCC/TCC.db"
[[ -n "${CI:-}" ]] || { echo "Refusing to run outside CI."; exit 0; }
[[ -d "$APP" ]] || { echo "No app at $APP; skipping."; exit 0; }

csrutil status 2>&1 | sed 's/^/  /' || true
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
# Ad-hoc signatures print their implicit requirement as "# designated => cdhash H…".
requirement="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p' | head -n 1)"
blob="$(mktemp)"
if ! csreq -r="$requirement" -b "$blob" 2>/dev/null; then
  echo "Couldn't compile the code requirement '$requirement'; skipping."
  exit 0
fi
hex="$(xxd -p "$blob" | tr -d '\n')"
now="$(date +%s)"
for service in kTCCServiceAccessibility kTCCServiceScreenCapture; do
  if sudo sqlite3 "$DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, last_modified) VALUES ('$service', '$identifier', 0, 2, 4, 1, X'$hex', 0, $now);" 2>&1; then
    echo "Allowed $service for $identifier"
  else
    echo "Couldn't allow $service (System Integrity Protection is probably on)"
  fi
done
# tccd reads the database again when it restarts.
sudo killall tccd 2>/dev/null || true
exit 0
