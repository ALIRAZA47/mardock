#!/bin/bash
# Verifies the security properties MarDock promises, on the built bundle:
#   • exact entitlements (sandbox + user-selected files; helper: none)
#   • Hardened Runtime on both executables, valid signatures
#   • no networking, process-spawning, scripting or dynamic-loading APIs
#     imported by either binary, and no Accessibility API in the app
#   • no API looked up by name at runtime, in the sources both are built from
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
  # grep reads everything (no -q): with pipefail, a `-q` that quits early
  # can make codesign fail with SIGPIPE and turn a pass into a failure.
  if codesign -dv "$target" 2>&1 | grep -E 'flags=0x[0-9a-f]*\(.*runtime' >/dev/null; then
    pass "Hardened Runtime: $(basename "$target")"
  else
    fail "Hardened Runtime missing: $(basename "$target")"
  fi
done

echo "Entitlements"
APP_KEYS="$(entitlement_keys "$APP")"
EXPECTED="com.apple.security.app-sandbox com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.read-write"
[[ "$APP_KEYS" == "$EXPECTED" ]] && pass "app: $APP_KEYS" || fail "app entitlements are '$APP_KEYS', expected '$EXPECTED'"
AGENT_KEYS="$(entitlement_keys "$AGENT")"
[[ -z "$AGENT_KEYS" ]] && pass "helper: none" || fail "helper has entitlements: $AGENT_KEYS"

echo "Imported symbols"
# Anything that could talk to the network, start processes, run scripts, load
# code at runtime, or look a class, selector or function up by name (which
# would hide any of the above from this scan). Notes: `kill` is allowed (the
# helper uses it to restart the Dock); `dlsym` is allowed in the app because
# Swift's runtime support code uses it to look up symbols in libraries that
# are already loaded — loading new code needs `dlopen`, which is forbidden
# (and blocked by library validation anyway).
FORBIDDEN='(^_socket$|^_connect$|^_getaddrinfo$|^_gethostbyname|^_nw_|URLSession|NSURLConnection|CFSocket|CFStreamCreatePairWithSocket|^_system$|^_popen$|^_posix_spawn|^_execv|^_execl|^_fork$|^_vfork$|NSTask|NSAppleScript|OSAScript|AuthorizationExecuteWithPrivileges|^_dlopen$|^_dlopen_preflight$|^_NSClassFromString$|^_NSSelectorFromString$|^_objc_getClass$|^_objc_lookUpClass$|^_objc_getRequiredClass$|^_sel_registerName$|^_sel_getUid$|NSUser(Unix|AppleScript|Automator|Script)Task|WKWebView)'
# Accessibility is the helper's job alone: macOS records that permission for
# MarDock.app as a whole, so the sandboxed app must never call those APIs.
# The helper, in turn, has no reason to look anything up with `dlsym`.
FORBIDDEN_IN_APP='(^_AXUIElement|^_AXIsProcessTrusted|^_AXObserver)'
FORBIDDEN_IN_HELPER='(^_dlsym$)'
for binary in "$APP/Contents/MacOS/MarDock" "$AGENT/Contents/MacOS/MarDockAgent"; do
  name="$(basename "$binary")"
  pattern="$FORBIDDEN"
  if [[ "$name" == MarDock ]]; then pattern+="|$FORBIDDEN_IN_APP"; else pattern+="|$FORBIDDEN_IN_HELPER"; fi
  hits=""
  for arch in $(lipo -archs "$binary"); do
    hits+="$(nm -u -arch "$arch" "$binary" 2>/dev/null | sed 's/^ *//' | grep -E "$pattern" || true)"$'\n'
  done
  hits="$(printf '%s' "$hits" | sed '/^$/d' | sort -u)"
  if [[ -z "$hits" ]]; then
    pass "$name imports no network/process/scripting/dlopen/lookup-by-name APIs"
  else
    fail "$name imports forbidden symbols:"; echo "$hits" | sed 's/^/      /'
  fi
  if otool -L "$binary" | grep -Eq 'Network.framework|WebKit.framework|CFNetwork.framework'; then
    fail "$name links a networking framework"
  else
    pass "$name links no networking frameworks"
  fi
done

echo "Sources"
# The import scan can't see an API looked up by name at runtime (`dlsym`,
# `NSClassFromString`, a selector made from a string), and Swift keeps short
# string literals inside the code, so the binaries' strings wouldn't show a
# "NSTask" either. So the sources both executables are built from are checked
# as well. SelfTest.swift is skipped: only the self-test build compiles it (it
# probes the sandbox with a real socket), never a build this audit runs on.
SOURCES="$(cd "$(dirname "$0")/.." && pwd)/Sources"
LOOKUPS='dlopen|dlsym|dladdr|NSClassFromString|NSSelectorFromString|Selector\("|objc_(getClass|lookUpClass|getRequiredClass|getMetaClass|msgSend|allocateClassPair)|sel_(registerName|getUid)|class_(addMethod|replaceMethod)|method_(exchange|set)Implementations|unsafeBitCast|@convention\(c\)|\.load\(\)|principalClass|classNamed\(|(^|[^.[:alnum:]_])(Process|NSTask|system|popen|fork|vfork|exec[vl]p?e?|posix_spawn[a-z_]*|socket|getaddrinfo|gethostbyname)\(|(^|[^.[:alnum:]_])connect\([^)]*,[^)]*,|NSAppleScript|OSAScript|NSUser[A-Za-z]*Task|AuthorizationExecute|URLSession|NSURLConnection|CFSocket|CFStreamCreatePairWithSocket|NWConnection|NWListener|WKWebView|JSContext'
if [[ ! -d "$SOURCES/MarDockAgent" ]]; then
  fail "sources not found at $SOURCES"
else
  hits="$(grep -rnE --include='*.swift' --exclude='SelfTest.swift' "$LOOKUPS" "$SOURCES")" && status=0 || status=$?
  case $status in
    1) pass "no forbidden APIs or lookups by name in the sources" ;;
    0) fail "the sources use a forbidden API or look one up by name:"; echo "$hits" | sed "s|^$SOURCES/|      |" ;;
    *) fail "could not scan the sources (grep exited $status)" ;;
  esac
fi

echo "Info.plist"
PLIST="$APP/Contents/Info.plist"
for key in CFBundleURLTypes NSAppTransportSecurity NSAppleEventsUsageDescription NSAppleScriptEnabled; do
  if plutil -extract "$key" raw -o - "$PLIST" >/dev/null 2>&1; then fail "unexpected $key"; else pass "no $key"; fi
done

echo "Bundle contents"
# Metadata.appintents is the Shortcuts actions' description: data, not code.
UNEXPECTED="$(cd "$APP" && find . -type f | grep -Ev '^\./Contents/(Info\.plist|PkgInfo|MacOS/MarDock|Resources/AppIcon\.icns|Resources/Metadata\.appintents/[A-Za-z0-9._-]+|_CodeSignature/CodeResources|XPCServices/[^/]+\.xpc/Contents/(Info\.plist|MacOS/MarDockAgent|_CodeSignature/CodeResources))$' || true)"
[[ -z "$UNEXPECTED" ]] && pass "only expected files" || { fail "unexpected files:"; echo "$UNEXPECTED" | sed 's/^/      /'; }

if [[ $FAILED -ne 0 ]]; then
  echo "Security audit FAILED"
  exit 1
fi
echo "Security audit passed"
