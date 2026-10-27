#!/bin/bash
# Packs MarDock.app into a compressed disk image with a shortcut to
# /Applications, and signs the image when given a Developer ID.
#
#   scripts/make-dmg.sh [app] [dmg]
#
# Environment: SIGN_IDENTITY ("-" or unset for an unsigned image).
set -euo pipefail

APP="${1:-build/MarDock.app}"
DMG="${2:-build/MarDock.dmg}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

[[ -d "$APP" ]] || { echo "error: no app at $APP" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$APP" "$staging/MarDock.app"
ln -s /Applications "$staging/Applications"

rm -f "$DMG"
hdiutil create -volname "MarDock" -srcfolder "$staging" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
