#!/bin/bash
# CI only: photographs every theme using the self-test build's --demo mode,
# plus the Settings and Welcome windows, and assembles a contact sheet.
set -uo pipefail

APP="${1:-build/selftest/MarDock.app}"
OUT="${2:-build/screenshots}"
THEMES="${THEMES:-glass liquid aurora midnight sunset mirror minimal}"
mkdir -p "$OUT"

# Move the runner's own Dock out of the way (the runner is disposable).
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
killall Dock 2>/dev/null || true
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
  "$APP/Contents/MacOS/MarDock" --demo --theme "$theme" --hover 0.42 >"$log" 2>&1 &
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

# Contact sheet (downscaled), printed as base64 so it can be read from the log.
python3 -m venv /tmp/shots-venv >/dev/null 2>&1 && /tmp/shots-venv/bin/pip install -q pillow >/dev/null 2>&1 || true
if [[ -x /tmp/shots-venv/bin/python ]]; then
  /tmp/shots-venv/bin/python - "$OUT" <<'PY'
import glob, os, sys
from PIL import Image
out = sys.argv[1]
docks = sorted(glob.glob(os.path.join(out, "dock-*.png")))
rows = []
for path in docks:
    im = Image.open(path).convert("RGB")
    scale = 900 / im.width
    rows.append(im.resize((900, max(1, int(im.height * scale))), Image.LANCZOS))
if rows:
    sheet = Image.new("RGB", (900, sum(r.height for r in rows)), "white")
    y = 0
    for r in rows:
        sheet.paste(r, (0, y)); y += r.height
    sheet.save(os.path.join(out, "sheet-docks.jpg"), quality=72)
for path in sorted(glob.glob(os.path.join(out, "window-*.png"))):
    im = Image.open(path).convert("RGB")
    scale = 760 / im.width
    im.resize((760, int(im.height * scale)), Image.LANCZOS).save(path.replace(".png", ".jpg"), quality=72)
PY
fi
for f in "$OUT"/sheet-docks.jpg "$OUT"/window-*.jpg; do
  [[ -f "$f" ]] || continue
  echo "BASE64-BEGIN $(basename "$f")"
  base64 -i "$f" | fold -w 120
  echo "BASE64-END $(basename "$f")"
done
exit 0
