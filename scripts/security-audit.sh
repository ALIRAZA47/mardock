#!/bin/bash
# Verifies the security properties MarDock promises, on the built bundle:
#   • exact entitlements (sandbox + user-selected read-only; helper: none)
#   • Hardened Runtime on both executables, valid signatures
#   • no networking, process-spawning, scripting or dynamic-loading APIs
#     imported by either binary
#   • no URL schemes, ATS exceptions or other surprises in Info.plist
set -euo pipefail

APP="${1:-build/MarDock.app}"
AGENT="$(find "$APP/Contents/XPCServices" -maxdepth 1 -name '*.xpc' | head -n 1)"
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=1; }

# Prints the names of all entitlements set to a truthy value, sorted.
entitlement_keys() {
  local xml
  xml="$(codesign -d --entitlements - --xml "$1" 2>/dev/null || true)"
  [[ -z "$xml" ]] && return 0
  printf '%s' "$xml" | plutil -convert json -o - - \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(k for k, v in d.items() if v)))'
}

echo "Signatures"
codesign --verify --deep --strict "$APP" && pass "bundle signature valid" || fail "bundle signature invalid"
for target in "$APP" "$AGENT"; do
  if codesign -dv "$target" 2>&1 | grep -Eq 'flags=0x[0-9a-f]*\(.*runtime'; then
    pass "Hardened Runtime: $(basename "$target")"
  else
    fail "Hardened Runtime missing: $(basename "$target")"
  fi
done

echo "Entitlements"
APP_KEYS="$(entitlement_keys "$APP")"
EXPECTED="com.apple.security.app-sandbox com.apple.security.files.user-selected.read-only"
[[ "$APP_KEYS" == "$EXPECTED" ]] && pass "app: $APP_KEYS" || fail "app entitlements are '$APP_KEYS', expected '$EXPECTED'"
AGENT_KEYS="$(entitlement_keys "$AGENT")"
[[ -z "$AGENT_KEYS" ]] && pass "helper: none" || fail "helper has entitlements: $AGENT_KEYS"

echo "Imported symbols"
# Anything that could talk to the network, start processes, run scripts or
# load code at runtime. (`kill` is allowed: the helper uses it to restart the Dock.)
FORBIDDEN='(^_socket$|^_connect$|^_getaddrinfo$|^_gethostbyname|^_nw_|URLSession|NSURLConnection|CFSocket|CFStreamCreatePairWithSocket|^_system$|^_popen$|^_posix_spawn|^_execv|^_execl|^_fork$|^_vfork$|NSTask|7ProcessC|NSAppleScript|OSAScript|AuthorizationExecuteWithPrivileges|^_dlopen$|^_dlsym$|NSUserScriptTask|WKWebView)'
for binary in "$APP/Contents/MacOS/MarDock" "$AGENT/Contents/MacOS/MarDockAgent"; do
  name="$(basename "$binary")"
  hits=""
  for arch in $(lipo -archs "$binary"); do
    hits+="$(nm -u -arch "$arch" "$binary" 2>/dev/null | sed 's/^ *//' | grep -E "$FORBIDDEN" || true)"
  done
  if [[ -z "$hits" ]]; then
    pass "$name imports no network/process/scripting/dlopen APIs"
  else
    fail "$name imports forbidden symbols:"; echo "$hits" | sort -u | sed 's/^/      /'
  fi
  if otool -L "$binary" | grep -Eq 'Network.framework|WebKit.framework|CFNetwork.framework'; then
    fail "$name links a networking framework"
  else
    pass "$name links no networking frameworks"
  fi
done

echo "Info.plist"
PLIST="$APP/Contents/Info.plist"
for key in CFBundleURLTypes NSAppTransportSecurity NSAppleEventsUsageDescription NSAppleScriptEnabled; do
  if plutil -extract "$key" raw -o - "$PLIST" >/dev/null 2>&1; then fail "unexpected $key"; else pass "no $key"; fi
done

echo "Bundle contents"
UNEXPECTED="$(cd "$APP" && find . -type f | grep -Ev '^\./Contents/(Info\.plist|PkgInfo|MacOS/MarDock|Resources/AppIcon\.icns|_CodeSignature/CodeResources|XPCServices/[^/]+\.xpc/Contents/(Info\.plist|MacOS/MarDockAgent|_CodeSignature/CodeResources))$' || true)"
[[ -z "$UNEXPECTED" ]] && pass "only expected files" || { fail "unexpected files:"; echo "$UNEXPECTED" | sed 's/^/      /'; }

if [[ $FAILED -ne 0 ]]; then
  echo "Security audit FAILED"
  exit 1
fi
echo "Security audit passed"
