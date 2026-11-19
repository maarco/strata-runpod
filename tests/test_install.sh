#!/bin/bash
# Tests for install.sh. Run: bash tests/test_install.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
fails=0; passes=0
check() { if eval "$2"; then echo "  PASS $1"; passes=$((passes+1)); else echo "  FAIL $1"; fails=$((fails+1)); fi; }
T="$(mktemp -d "${STRATA_TEST_TMP:-$ROOT/.test-tmp}.install.XXXXXX")"

echo "== I1: installs every command as a symlink into PREFIX"
out=$(PREFIX="$T/bin" bash "$ROOT/install.sh" 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
for c in strata-pod strata-on strata-cc strata-codex strata-off strata-status strata-env strata-extend strata-logs strata-dash; do
  check "$c linked" '[ -L "$T/bin/$c" ] && [ -x "$T/bin/$c" ]'
done
check "strata-dash points at the dashboard" '[ "$(basename "$(readlink "$T/bin/strata-dash")")" = strata-dash ]'
check "says the next step" 'echo "$out" | grep -q "strata-pod setup"'

echo "== I2: running it again is fine (idempotent)"
PREFIX="$T/bin" bash "$ROOT/install.sh" >/dev/null 2>&1; rc=$?
check "exit 0" '[ $rc = 0 ]'

echo "== I3: never overwrites a real file of the same name"
rm "$T/bin/strata-on"; echo "mine" > "$T/bin/strata-on"
out=$(PREFIX="$T/bin" bash "$ROOT/install.sh" 2>&1); rc=$?
check "exit non-zero" '[ $rc != 0 ]'
check "file kept" '[ "$(cat "$T/bin/strata-on")" = mine ]'
check "names the file" 'echo "$out" | grep -q "strata-on"'

echo "== I4: installed command runs from anywhere (finds its repo through the symlink)"
rm "$T/bin/strata-on"; PREFIX="$T/bin" bash "$ROOT/install.sh" >/dev/null 2>&1
out=$(cd / && "$T/bin/strata-pod" help 2>&1)
check "help works via the link" 'echo "$out" | grep -q "strata-on"'

echo "== I5: warns when PREFIX is not on PATH"
out=$(PATH=/usr/bin:/bin PREFIX="$T/bin" bash "$ROOT/install.sh" 2>&1)
check "PATH hint" 'echo "$out" | grep -q "PATH"'

python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$T"
echo; echo "passed $passes, failed $fails"; [ "$fails" = 0 ]
