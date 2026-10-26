#!/bin/bash
# CI only: records the real app playing a scripted tour of the dock
# (`--demo --tour`, self-test builds) and leaves tour.mp4 in the output folder.
# If the runner can't record video, it falls back to a burst of screenshots.
set -uo pipefail

APP="${1:-build/selftest/MarDock.app}"
OUT="${2:-build/tour}"
mkdir -p "$OUT"

# Move the runner's own Dock out of the way; let the glass and the motion show.
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
killall Dock 2>/dev/null || true
defaults write com.apple.universalaccess reduceTransparency -bool false 2>&1 || true
defaults write com.apple.universalaccess reduceMotion -bool false 2>&1 || true
echo "reduceMotion: $(defaults read com.apple.universalaccess reduceMotion 2>&1)"
sleep 3

TOUR_PID=""

start_tour() { # log file
  "$APP/Contents/MacOS/MarDock" --demo --tour --backdrop >"$1" 2>&1 &
  TOUR_PID=$!
  for _ in $(seq 1 80); do
    grep -q "TOUR READY" "$1" && return 0
    sleep 0.25
  done
  echo "the tour never became ready"
  cat "$1"
  kill "$TOUR_PID" 2>/dev/null
  return 1
}

wait_for_tour() {
  for _ in $(seq 1 150); do
    kill -0 "$TOUR_PID" 2>/dev/null || break
    sleep 0.5
  done
  kill "$TOUR_PID" 2>/dev/null
  wait "$TOUR_PID" 2>/dev/null
}

# 1. A real screen recording.
start_tour "$OUT/tour.log" || exit 0
secs="$(sed -n 's/^TOUR READY \([0-9]*\).*/\1/p' "$OUT/tour.log" | head -n 1)"
secs="${secs:-40}"
screencapture -v -V "$secs" -x "$OUT/tour.mov" >"$OUT/recorder.log" 2>&1 &
recorder=$!
wait_for_tour
for _ in $(seq 1 30); do
  kill -0 "$recorder" 2>/dev/null || break
  sleep 1
done
kill -INT "$recorder" 2>/dev/null
wait "$recorder" 2>/dev/null
cat "$OUT/tour.log" "$OUT/recorder.log"

if [ -s "$OUT/tour.mov" ]; then
  if avconvert --source "$OUT/tour.mov" --output "$OUT/tour.mp4" --preset PresetHighestQuality --replace; then
    rm -f "$OUT/tour.mov"
  else
    echo "avconvert failed; keeping the .mov"
  fi
  ls -la "$OUT"
  exit 0
fi

# 2. No video: photograph the screen as fast as it allows, then stitch the frames.
echo "no video was recorded; falling back to screenshots"
mkdir -p "$OUT/frames"
start_tour "$OUT/tour-frames.log" || exit 0
count=0
began=$(date +%s)
while kill -0 "$TOUR_PID" 2>/dev/null; do
  screencapture -x -t jpg "$OUT/frames/$(printf %05d "$count").jpg" && count=$((count + 1))
done
ended=$(date +%s)
wait_for_tour
echo "captured $count frames in $((ended - began)) s"

venv="$(mktemp -d)/venv"
if python3 -m venv "$venv" && "$venv/bin/pip" install --quiet imageio imageio-ffmpeg; then
  "$venv/bin/python" - "$OUT/frames" "$OUT/tour.mp4" "$count" "$((ended - began))" <<'PY'
import glob
import sys

import imageio.v2 as imageio

frames = sorted(glob.glob(sys.argv[1] + "/*.jpg"))
fps = max(1, round(int(sys.argv[3]) / max(1, int(sys.argv[4]))))
with imageio.get_writer(sys.argv[2], fps=fps, codec="libx264", quality=8, macro_block_size=8) as writer:
    for frame in frames:
        writer.append_data(imageio.imread(frame))
print(f"wrote {len(frames)} frames at {fps} fps")
PY
  rm -rf "$OUT/frames"
else
  echo "couldn't set up the frame stitcher; keeping the frames"
fi
ls -la "$OUT"
exit 0
