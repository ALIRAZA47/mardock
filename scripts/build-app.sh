#!/bin/bash
# Builds MarDock.app: compiles with SwiftPM, assembles the bundle (app +
# embedded XPC helper), and signs both with the Hardened Runtime.
#
# Environment (all optional):
#   SIGN_IDENTITY   "-" for an ad-hoc signature (default), or e.g.
#                   "Developer ID Application: Your Name (TEAMID)"
#   BUNDLE_ID       default io.github.aliraza47.MarDock
#   VERSION         default 1.0.0
#   BUILD_NUMBER    default: number of commits
#   ARCHS           default "arm64 x86_64" (universal; this Mac's arch when
#                   only the Command Line Tools are installed)
#   CONFIGURATION   default release
#   OUTPUT_DIR      default build
#   SCRATCH         SwiftPM scratch path, default .build
#   SWIFT_FLAGS     extra flags for swift build (used for self-test builds)
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="${BUNDLE_ID:-io.github.aliraza47.MarDock}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# Universal builds need Xcode's build system; with only the Command Line
# Tools, build for this Mac's architecture.
if [[ -z "${ARCHS:-}" ]]; then
  if xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
    ARCHS="$(uname -m)"
  else
    ARCHS="arm64 x86_64"
  fi
fi
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-build}"
SCRATCH="${SCRATCH:-.build}"
SWIFT_FLAGS="${SWIFT_FLAGS:-}"

# These values end up in plists and code requirements; keep them boring.
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo "error: invalid BUNDLE_ID" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "error: invalid VERSION" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "error: invalid BUILD_NUMBER" >&2; exit 1; }

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

echo "▸ Compiling ($CONFIGURATION, $ARCHS)"
# shellcheck disable=SC2086 # SWIFT_FLAGS is intentionally word-split.
swift build -c "$CONFIGURATION" "${ARCH_FLAGS[@]}" --scratch-path "$SCRATCH" $SWIFT_FLAGS
BIN_DIR="$(swift build -c "$CONFIGURATION" "${ARCH_FLAGS[@]}" --scratch-path "$SCRATCH" --show-bin-path)"

APP="$OUTPUT_DIR/MarDock.app"
AGENT="$APP/Contents/XPCServices/$BUNDLE_ID.Agent.xpc"
echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$AGENT/Contents/MacOS"

cp "$BIN_DIR/MarDock" "$APP/Contents/MacOS/MarDock"
cp "$BIN_DIR/MarDockAgent" "$AGENT/Contents/MacOS/MarDockAgent"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

substitute() {
  sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" "$1" > "$2"
}
substitute App/Info.plist "$APP/Contents/Info.plist"
substitute App/Agent-Info.plist "$AGENT/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" "$AGENT/Contents/Info.plist" >/dev/null

echo "▸ Signing with ${SIGN_IDENTITY/#-/ad-hoc identity}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  TIMESTAMP=(--timestamp=none)
else
  TIMESTAMP=(--timestamp)
fi
# Inside-out: the helper first (Hardened Runtime, no entitlements at all),
# then the app (Hardened Runtime + App Sandbox).
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$SIGN_IDENTITY" "$AGENT"
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements App/MarDock.entitlements --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ Built $APP"
lipo -info "$APP/Contents/MacOS/MarDock" | sed 's/^/  /'
