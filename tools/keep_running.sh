#!/bin/bash
# Keeps the Win98 run going: resumes from the newest checkpoint if the process dies. Log only, no fixes.
cd "$(dirname "$0")/.."
SNAP=tools/out/w98pm.snap
while true; do
  L=$(ls -t tools/out/w98keep.snap.* 2>/dev/null | head -1)
  [ -n "$L" ] && SNAP=$L
  echo "[keep] starting from $SNAP at $(date)" >> tools/out/run_live.txt
  tools/bin/lune.exe run tools/win98_run.lua --load "$SNAP" --budget 200000 --save tools/out/w98keep.snap --save-every 250 --end-text 1 >> tools/out/run_live.txt 2>&1
  echo "[keep] exited $? at $(date)" >> tools/out/run_live.txt
  sleep 5
done
