#!/bin/bash
# Runs the end-to-end self-test of a MARDOCK_SELFTEST build, with a watchdog.
set -uo pipefail

APP="${1:-build/selftest/MarDock.app}"
LOG="$(mktemp -t mardock-selftest).log"

"$APP/Contents/MacOS/MarDock" --self-test >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 180); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "Self-test timed out"
  kill -9 "$PID"
  cat "$LOG"
  exit 1
fi
wait "$PID"
STATUS=$?
cat "$LOG"
grep -q "SELFTEST RESULT PASS" "$LOG" && [[ $STATUS -eq 0 ]]
