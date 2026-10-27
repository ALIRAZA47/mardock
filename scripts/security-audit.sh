#!/bin/bash
# Verifies the security properties MarDock promises, on the built bundle:
#   • exact entitlements (app: sandbox, user-selected files, Apple Events to
#     Finder's Trash commands only; helper: none; updater: sandbox + outgoing
#     network)
#   • Hardened Runtime on all three executables, valid signatures
#   • no process-spawning, scripting or dynamic-loading APIs imported by any
#     binary, no networking outside the updater, and no Accessibility API in
#     the app
#   • no API looked up by name at runtime, in the sources they're built from
#   • no URL schemes, ATS exceptions or other surprises in the Info.plists
set -euo pipefail

APP="${1:-build/MarDock.app}"
AGENT="$(find "$APP/Contents/XPCServices" -maxdepth 1 -name '*.Agent.xpc' | head -n 1)"
UPDATER="$(find "$APP/Contents/XPCServices" -maxdepth 1 -name '*.Updater.xpc' | head -n 1)"
[[ -n "$AGENT" && -n "$UPDATER" ]] || { echo "  ✗ helper or updater missing from $APP"; exit 1; }
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
for target in "$APP" "$AGENT" "$UPDATER"; do
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
EXPECTED="com.apple.security.app-sandbox com.apple.security.automation.apple-events com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.read-write com.apple.security.scripting-targets"
[[ "$APP_KEYS" == "$EXPECTED" ]] && pass "app: $APP_KEYS" || fail "app entitlements are '$APP_KEYS', expected '$EXPECTED'"
# Apple Events may go to Finder only, and only for its Trash commands.
TARGETS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - \
  | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("com.apple.security.scripting-targets"), sort_keys=True))')"
[[ "$TARGETS" == '{"com.apple.finder": ["com.apple.finder.trash"]}' ]] && pass "Apple Events: Finder's Trash commands only" || fail "scripting targets are $TARGETS"
AGENT_KEYS="$(entitlement_keys "$AGENT")"
[[ -z "$AGENT_KEYS" ]] && pass "helper: none" || fail "helper has entitlements: $AGENT_KEYS"
UPDATER_KEYS="$(entitlement_keys "$UPDATER")"
EXPECTED="com.apple.security.app-sandbox com.apple.security.network.client"
[[ "$UPDATER_KEYS" == "$EXPECTED" ]] && pass "updater: $UPDATER_KEYS" || fail "updater entitlements are '$UPDATER_KEYS', expected '$EXPECTED'"

echo "Imported symbols"
# Anything that could start processes, run scripts, load code at runtime, or
# look a class, selector or function up by name (which would hide any of the
# above from this scan) — and, except in the updater, talk to the network. Notes: `kill` is allowed (the
# helper uses it to restart the Dock); `dlsym` is allowed in the app because
# Swift's runtime support code uses it to look up symbols in libraries that
# are already loaded — loading new code needs `dlopen`, which is forbidden
# (and blocked by library validation anyway).
NETWORK='^_socket$|^_connect$|^_getaddrinfo$|^_gethostbyname|^_nw_|URLSession|NSURLConnection|CFSocket|CFStreamCreatePairWithSocket'
FORBIDDEN='(^_system$|^_popen$|^_posix_spawn|^_execv|^_execl|^_fork$|^_vfork$|NSTask|NSAppleScript|OSAScript|AuthorizationExecuteWithPrivileges|^_dlopen$|^_dlopen_preflight$|^_NSClassFromString$|^_NSSelectorFromString$|^_objc_getClass$|^_objc_lookUpClass$|^_objc_getRequiredClass$|^_sel_registerName$|^_sel_getUid$|NSUser(Unix|AppleScript|Automator|Script)Task|WKWebView)'
# Accessibility is the helper's job alone: macOS records that permission for
# MarDock.app as a whole, so the sandboxed app must never call those APIs.
# The helper, in turn, has no reason to look anything up with `dlsym`.
FORBIDDEN_IN_APP='(^_AXUIElement|^_AXIsProcessTrusted|^_AXObserver)'
FORBIDDEN_IN_HELPER='(^_dlsym$)'
for binary in "$APP/Contents/MacOS/MarDock" "$AGENT/Contents/MacOS/MarDockAgent" "$UPDATER/Contents/MacOS/MarDockUpdater"; do
  name="$(basename "$binary")"
  pattern="$FORBIDDEN"
  case "$name" in
    MarDock) pattern+="|$NETWORK|$FORBIDDEN_IN_APP" ;;
    MarDockAgent) pattern+="|$NETWORK|$FORBIDDEN_IN_HELPER" ;;
    MarDockUpdater) pattern+="|$FORBIDDEN_IN_APP|$FORBIDDEN_IN_HELPER" ;;
  esac
  hits=""
  for arch in $(lipo -archs "$binary"); do
    hits+="$(nm -u -arch "$arch" "$binary" 2>/dev/null | sed 's/^ *//' | grep -E "$pattern" || true)"$'\n'
  done
  hits="$(printf '%s' "$hits" | sed '/^$/d' | sort -u)"
  if [[ -z "$hits" ]]; then
    if [[ "$name" == MarDockUpdater ]]; then
      pass "$name imports no process/scripting/dlopen/lookup-by-name APIs (networking is its job)"
    else
      pass "$name imports no network/process/scripting/dlopen/lookup-by-name APIs"
    fi
  else
    fail "$name imports forbidden symbols:"; echo "$hits" | sed 's/^/      /'
  fi
  if [[ "$name" == MarDockUpdater ]]; then
    if otool -L "$binary" | grep -Eq 'WebKit.framework'; then fail "$name links WebKit"; else pass "$name links no WebKit"; fi
  elif otool -L "$binary" | grep -Eq 'Network.framework|WebKit.framework|CFNetwork.framework'; then
    fail "$name links a networking framework"
  else
    pass "$name links no networking frameworks"
  fi
done

echo "Sources"
# The import scan can't see an API looked up by name at runtime (`dlsym`,
# `NSClassFromString`, a selector made from a string), and Swift keeps short
# string literals inside the code, so the binaries' strings wouldn't show a
# "NSTask" either. So the sources the executables are built from are checked
# as well. SelfTest.swift is skipped: only the self-test build compiles it (it
# probes the sandbox with a real socket), never a build this audit runs on.
# Networking APIs are only allowed in the updater's own sources.
SOURCES="$(cd "$(dirname "$0")/.." && pwd)/Sources"
LOOKUPS='dlopen|dlsym|dladdr|NSClassFromString|NSSelectorFromString|Selector\("|objc_(getClass|lookUpClass|getRequiredClass|getMetaClass|msgSend|allocateClassPair)|sel_(registerName|getUid)|class_(addMethod|replaceMethod)|method_(exchange|set)Implementations|unsafeBitCast|@convention\(c\)|\.load\(\)|principalClass|classNamed\(|(^|[^.[:alnum:]_])(Process|NSTask|system|popen|fork|vfork|exec[vl]p?e?|posix_spawn[a-z_]*)\(|NSAppleScript|OSAScript|NSUser[A-Za-z]*Task|AuthorizationExecute|WKWebView|JSContext'
NETWORK_SOURCES='(^|[^.[:alnum:]_])(socket|getaddrinfo|gethostbyname)\(|(^|[^.[:alnum:]_])connect\([^)]*,[^)]*,|URLSession|NSURLConnection|CFSocket|CFStreamCreatePairWithSocket|NWConnection|NWListener'
if [[ ! -d "$SOURCES/MarDockAgent" ]]; then
  fail "sources not found at $SOURCES"
else
  hits="$(grep -rnE --include='*.swift' --exclude='SelfTest.swift' "$LOOKUPS" "$SOURCES")" && status=0 || status=$?
  case $status in
    1) pass "no forbidden APIs or lookups by name in the sources" ;;
    0) fail "the sources use a forbidden API or look one up by name:"; echo "$hits" | sed "s|^$SOURCES/|      |" ;;
    *) fail "could not scan the sources (grep exited $status)" ;;
  esac
  hits="$(grep -rnE --include='*.swift' --exclude='SelfTest.swift' --exclude-dir='MarDockUpdater' "$NETWORK_SOURCES" "$SOURCES")" && status=0 || status=$?
  case $status in
    1) pass "no networking outside the updater's sources" ;;
    0) fail "networking outside the updater:"; echo "$hits" | sed "s|^$SOURCES/|      |" ;;
    *) fail "could not scan the sources (grep exited $status)" ;;
  esac
fi

echo "Info.plist"
# NSAppleEventsUsageDescription is expected: it's what macOS shows when it
# asks whether MarDock may have Finder empty the Trash.
for PLIST in "$APP/Contents/Info.plist" "$AGENT/Contents/Info.plist" "$UPDATER/Contents/Info.plist"; do
  where="$(basename "$(dirname "$(dirname "$PLIST")")")"
  for key in CFBundleURLTypes NSAppTransportSecurity NSAppleScriptEnabled; do
    if plutil -extract "$key" raw -o - "$PLIST" >/dev/null 2>&1; then fail "$where: unexpected $key"; else pass "$where: no $key"; fi
  done
done

echo "Bundle contents"
# Metadata.appintents is the Shortcuts actions' description: data, not code.
UNEXPECTED="$(cd "$APP" && find . -type f | grep -Ev '^\./Contents/(Info\.plist|PkgInfo|MacOS/MarDock|Resources/AppIcon\.icns|Resources/Metadata\.appintents/[A-Za-z0-9._-]+|_CodeSignature/CodeResources|XPCServices/[^/]+\.Agent\.xpc/Contents/(Info\.plist|MacOS/MarDockAgent|_CodeSignature/CodeResources)|XPCServices/[^/]+\.Updater\.xpc/Contents/(Info\.plist|MacOS/MarDockUpdater|_CodeSignature/CodeResources))$' || true)"
[[ -z "$UNEXPECTED" ]] && pass "only expected files" || { fail "unexpected files:"; echo "$UNEXPECTED" | sed 's/^/      /'; }

if [[ $FAILED -ne 0 ]]; then
  echo "Security audit FAILED"
  exit 1
fi
echo "Security audit passed"
