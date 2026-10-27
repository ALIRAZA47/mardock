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

# Shortcuts finds an app's actions through Metadata.appintents in its
# Resources, which Xcode extracts at build time and SwiftPM doesn't. So do
# what Xcode does: have the compiler write out the compile-time values of
# the App Intents types, then run Apple's extractor on them (below).
INTENTS_DIR="$(mkdir -p "$SCRATCH/appintents" && cd "$SCRATCH/appintents" && pwd)"
printf '%s\n' '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]' \
  > "$INTENTS_DIR/protocols.json"
CONST_FLAGS=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$INTENTS_DIR/protocols.json")

echo "▸ Compiling ($CONFIGURATION, $ARCHS)"
# shellcheck disable=SC2086 # SWIFT_FLAGS is intentionally word-split.
swift build -c "$CONFIGURATION" "${ARCH_FLAGS[@]}" --scratch-path "$SCRATCH" "${CONST_FLAGS[@]}" $SWIFT_FLAGS
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "$CONFIGURATION" "${ARCH_FLAGS[@]}" --scratch-path "$SCRATCH" "${CONST_FLAGS[@]}" $SWIFT_FLAGS --show-bin-path)"

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

echo "▸ Extracting Shortcuts actions"
extract_app_intents() {
  local processor consts xcode_build triples=()
  processor="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
  if [[ -z "$processor" ]]; then
    echo "  warning: appintentsmetadataprocessor needs Xcode; MarDock's actions won't appear in Shortcuts"
    return 0
  fi
  # The app module's values, newest first (they're the same for every architecture).
  consts="$(grep -rl --include='*.swiftconstvalues' 'SwitchProfileIntent' "$SCRATCH" 2>/dev/null \
    | xargs ls -t 2>/dev/null | head -n 1 || true)"
  if [[ -z "$consts" ]]; then
    echo "  warning: the compiler wrote no App Intents values; MarDock's actions won't appear in Shortcuts"
    return 0
  fi
  echo "  values: $consts"
  find "$PWD/Sources/MarDock" -name '*.swift' | sort > "$INTENTS_DIR/sources.txt"
  printf '%s\n' "$consts" > "$INTENTS_DIR/constvalues.txt"
  : > "$INTENTS_DIR/metadata.txt"
  : > "$INTENTS_DIR/static-metadata.txt"
  for arch in $ARCHS; do triples+=(--target-triple "$arch-apple-macos14.0"); done
  xcode_build="$(xcodebuild -version 2>/dev/null | awk '/Build version/ { print $3 }')"
  "$processor" \
    --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
    --module-name MarDock \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "${xcode_build:-unknown}" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --bundle-identifier "$BUNDLE_ID" \
    --output "$APP/Contents/Resources" \
    "${triples[@]}" \
    --binary-file "$APP/Contents/MacOS/MarDock" \
    --stringsdata-file "$INTENTS_DIR/ExtractedAppShortcutsMetadata.stringsdata" \
    --source-file-list "$INTENTS_DIR/sources.txt" \
    --metadata-file-list "$INTENTS_DIR/metadata.txt" \
    --static-metadata-file-list "$INTENTS_DIR/static-metadata.txt" \
    --swift-const-vals-list "$INTENTS_DIR/constvalues.txt" \
    --compile-time-extraction \
    --deployment-aware-processing \
    --no-app-shortcuts-localization \
    || echo "  warning: appintentsmetadataprocessor failed; MarDock's actions won't appear in Shortcuts"
  if [[ -d "$APP/Contents/Resources/Metadata.appintents" ]]; then
    ls "$APP/Contents/Resources/Metadata.appintents" | sed 's/^/  /'
  fi
}
extract_app_intents

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
