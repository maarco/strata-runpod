#!/bin/bash
# Tests for scripts/gpu-ttl with real timer processes (they only sleep; nothing reaches RunPod).
# Run: bash tests/test_ttl.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
fails=0; passes=0
check() { if eval "$2"; then echo "  PASS $1"; passes=$((passes+1)); else echo "  FAIL $1"; fails=$((fails+1)); fi; }
T="$(mktemp -d "${STRATA_TEST_TMP:-$ROOT/.test-tmp}.ttl.XXXXXX")"
POD="ttltest$$"
alive() { pgrep -f "/pods/$POD" >/dev/null 2>&1; }

# a second checkout of the scripts, as when the commands moved from one folder to another
mkdir -p "$T/other/scripts/lib" "$T/other/scripts/providers"
cp "$ROOT/scripts/gpu-ttl" "$T/other/scripts/"; cp "$ROOT/scripts/lib/common.sh" "$T/other/scripts/lib/"
cp "$ROOT/scripts/providers/runpod.sh" "$T/other/scripts/providers/"

echo "== L1: cancel from one checkout ends a timer armed from another checkout"
RUNPOD_API_KEY=x "$T/other/scripts/gpu-ttl" "$POD" 5 >/dev/null 2>&1
sleep 1
check "timer from the other checkout is running" 'alive'
RUNPOD_API_KEY=x "$ROOT/scripts/gpu-ttl" --cancel "$POD" >/dev/null 2>&1
sleep 1
check "gone after cancel from this checkout" '! alive'

echo "== L2: cancel ends every timer for the pod (two armed) and their sleep children"
RUNPOD_API_KEY=x "$ROOT/scripts/gpu-ttl" "$POD" 5 >/dev/null 2>&1
RUNPOD_API_KEY=x "$T/other/scripts/gpu-ttl" "$POD" 6 >/dev/null 2>&1
sleep 1
check "two timers running" '[ "$(pgrep -f "/pods/$POD" | wc -l | tr -d " ")" -ge 2 ]'
RUNPOD_API_KEY=x "$ROOT/scripts/gpu-ttl" --cancel "$POD" >/dev/null 2>&1
sleep 1
check "all timers gone" '! alive'
check "no orphaned 5 h / 6 h sleeps" '! pgrep -x -f "sleep 18000" >/dev/null && ! pgrep -x -f "sleep 21600" >/dev/null'

echo "== L3: cancel leaves other pods' timers alone"
RUNPOD_API_KEY=x "$ROOT/scripts/gpu-ttl" "$POD" 5 >/dev/null 2>&1
RUNPOD_API_KEY=x "$ROOT/scripts/gpu-ttl" "${POD}other" 5 >/dev/null 2>&1
sleep 1
RUNPOD_API_KEY=x "$ROOT/scripts/gpu-ttl" --cancel "$POD" >/dev/null 2>&1
sleep 1
check "this pod's timer gone" '! pgrep -f "/pods/$POD'"'"'" >/dev/null'
check "the other pod's timer still running" 'pgrep -f "/pods/${POD}other" >/dev/null'
RUNPOD_API_KEY=x "$ROOT/scripts/gpu-ttl" --cancel "${POD}other" >/dev/null 2>&1

python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$T"
echo; echo "passed $passes, failed $fails"; [ "$fails" = 0 ]
