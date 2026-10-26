#!/bin/bash
# CI only: photographs every theme using the self-test build's --demo mode,
# plus a side dock and the Settings and Welcome windows. The images are
# uploaded as a build artifact.
set -uo pipefail

APP="${1:-build/selftest/MarDock.app}"
OUT="${2:-build/screenshots}"
THEMES="${THEMES:-glass liquid aurora midnight sunset mirror minimal}"
mkdir -p "$OUT"
[[ -x "$APP/Contents/MacOS/MarDock" ]] || { echo "No app at $APP (did the build fail?); skipping screenshots."; exit 0; }

# Move the runner's own Dock out of the way (the runner is disposable).
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
killall Dock 2>/dev/null || true
# Screenshots should show real translucency.
echo "reduceTransparency: $(defaults read com.apple.universalaccess reduceTransparency 2>&1)"
defaults write com.apple.universalaccess reduceTransparency -bool false 2>&1 || true
sleep 3

wait_for() { # file pattern
  for _ in $(seq 1 60); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.25; done
  return 1
}

rect_from() { # log line-prefix → "x,y,w,h"
  sed -n "s/^$2 (\([^)]*\)).*/\1/p" "$1" | head -n 1 | tr -d ' ' | awk -F, '{printf "%d,%d,%d,%d", $1, $2, $3, $4}'
}

for theme in $THEMES; do
  log="$OUT/$theme.log"
  "$APP/Contents/MacOS/MarDock" --demo --theme "$theme" --hover 0.42 --backdrop >"$log" 2>&1 &
  pid=$!
  if wait_for "$log" "DEMO READY"; then
    sleep 1
    rect="$(rect_from "$log" "DEMO READY")"
    screencapture -x -t png -R"$rect" "$OUT/dock-$theme.png" || echo "screencapture failed for $theme"
  else
    echo "demo for $theme never became ready"; cat "$log"
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
done

# A side dock, to check the vertical layout.
log="$OUT/vertical.log"
"$APP/Contents/MacOS/MarDock" --demo --theme midnight --position left --hover 0.5 --backdrop >"$log" 2>&1 &
pid=$!
if wait_for "$log" "DEMO READY"; then
  sleep 1
  screencapture -x -t png -R"$(rect_from "$log" "DEMO READY")" "$OUT/vertical-midnight.png" || echo "screencapture failed (vertical)"
else
  echo "vertical demo never became ready"; cat "$log"
fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

for window in settings welcome; do
  log="$OUT/$window.log"
  "$APP/Contents/MacOS/MarDock" --demo --theme aurora --window "$window" >"$log" 2>&1 &
  pid=$!
  if wait_for "$log" "DEMO WINDOW"; then
    sleep 1.5
    rect="$(rect_from "$log" "DEMO WINDOW")"
    screencapture -x -t png -R"$rect" "$OUT/window-$window.png" || echo "screencapture failed for $window"
  else
    echo "window $window never appeared"; cat "$log"
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
done

ls -la "$OUT"

exit 0
