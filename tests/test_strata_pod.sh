#!/bin/bash
# Tests for strata-pod (strata-on / strata-cc / strata-off / strata-status / strata-env / strata-extend).
# Run: bash tests/test_strata_pod.sh
# Offline: RunPod and Strata are a fake curl (strata_fake_curl.py), gpu-hunt-many / gpu-ttl and claude are stubs.
# Nothing here can rent a pod or spend money.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
POD="$HERE/../bin/strata-pod"
WORK="${STRATA_TEST_TMP:-$HERE/../.test-tmp}"
mkdir -p "$WORK"
fails=0; passes=0

pass() { echo "  PASS $1"; passes=$((passes+1)); }
fail() { echo "  FAIL $1"; fails=$((fails+1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# a fresh sandbox per test: fake llm-cloud-runtime, config dir, stub dir, bin dir with curl/claude
setup() {
  T="$(mktemp -d "$WORK/t.XXXXXX")"
  export STUB="$T/stub" STRATA_LCR="$T/lcr" STRATA_CONF_DIR="$T/conf"
  mkdir -p "$STUB" "$STRATA_LCR/scripts" "$STRATA_LCR/.runtime" "$T/bin"
  echo 'RUNPOD_API_KEY=rp-test-key' > "$STRATA_LCR/.env"
  mkdir -p "$STRATA_LCR/profiles"; echo 'RUNPOD_VOLUME_GB=120' > "$STRATA_LCR/profiles/strata.env"
  # gpu-hunt-many stub: records how it was called, "catches" pod fake123 unless HUNT_FAIL=1
  cat > "$STRATA_LCR/scripts/gpu-hunt-many" <<'EOF'
#!/bin/bash
printf '%s\n' "cards=$1" "args=${*:2}" "PROFILE=${PROFILE:-}" "POD_ENV=${RUNPOD_POD_ENV:-}" \
  "INSTANCE_NAME=${INSTANCE_NAME:-}" "HUNT_RUN=${HUNT_RUN:-}" "RESULT=${HUNT_RESULT_FILE:-}" \
  "RUNPOD_API_KEY=${RUNPOD_API_KEY:-}" "ENTRY=${RUNPOD_ENTRYPOINT_JSON:-}" "CMD=${RUNPOD_CMD_JSON:-}" > "$STUB/hunt.log"
[ "${HUNT_FAIL:-0}" = 1 ] && { echo "no gpu caught; nothing billed" >&2; exit 1; }
[ -n "${HUNT_RESULT_FILE:-}" ] || { echo "no HUNT_RESULT_FILE" >&2; exit 1; }
echo "{\"id\":\"${FAKE_POD_ID:-fake123}\",\"gpu\":{\"id\":\"NVIDIA GeForce RTX 5080\"}}" > "$HUNT_RESULT_FILE"
EOF
  cat > "$STRATA_LCR/scripts/gpu-ttl" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB/ttl.log"
echo "${RUNPOD_API_KEY:-}" >> "$STUB/ttl.key"
EOF
  chmod +x "$STRATA_LCR/scripts/"*
  cat > "$T/bin/codex" <<'EOF'
#!/bin/bash
env | grep -E '^(STRATA_API_KEY|OPENAI_|CODEX_HOME)' | sort > "$STUB/codex.env"
printf '%s\n' "$@" > "$STUB/codex.args"
EOF
  chmod +x "$T/bin/codex"
  cat > "$T/bin/claude" <<'EOF'
#!/bin/bash
env | grep -E '^(ANTHROPIC_|CLAUDE_CODE_|DISABLE_|MAX_THINKING)' | sort > "$STUB/claude.env"
printf '%s\n' "$@" > "$STUB/claude.args"
EOF
  chmod +x "$T/bin/claude"
  export STRATA_CURL="python3 $HERE/strata_fake_curl.py" STRATA_CLAUDE="$T/bin/claude" STRATA_CODEX="$T/bin/codex"
  export RUNPOD_API_BASE="https://rp.test/v2" STRATA_URL_FMT="https://%s.strata.test"
  export STRATA_POLL_S=0 STRATA_READY_TIMEOUT_S=5
  unset HUNT_FAIL ANTHROPIC_API_KEY RUNPOD_API_KEY STRATA_POD FAKE_POD_ID
  : > "$STUB/calls.log"
}
routes() { cat > "$STUB/routes.json"; }
calls() { cat "$STUB/calls.log"; }
state_pod() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("pod_id",""))' "$STRATA_CONF_DIR/pods/${1:-1}.json" 2>/dev/null; }

# a loaded server answering /v1/models with a 131072 context, a pod with 104 GB RAM
LOADED='{"code":200,"body":{"data":[{"id":"qwen3.8-flash-next-iq3_xxs","status":{"value":"loaded"},"meta":{"n_ctx":131072}}]}}'
POD_RUNNING='{"code":200,"body":{"id":"fake123","status":"RUNNING","cost":0.39,"gpu":{"id":"NVIDIA GeForce RTX 5080","memory":104},"env":{"FAMILY":"qwen","MODEL":"IQ3_XXS","API_KEY":"k","CONTEXT":"128k"}}}'
MSG_OK='{"code":200,"body":{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":12,"output_tokens":2}}}'

echo "== T1: strata-on with no pod: hunts, caps memory, sets a ttl, waits until loaded, smoke-tests"
setup
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$POD_RUNNING],
 "PATCH rp.test/v2/pods/fake123": [$POD_RUNNING],
 "GET rp.test/v2/pods/fake123/logs": [{"code":200,"body":"data: {\"line\":\"Downloading the model files: 10.0 of 76.7 GB\"}\n"}],
 "GET fake123.strata.test/v1/models": [{"code":502,"body":"bad gateway"}, $LOADED],
 "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
out=$("$POD" on 2>&1); rc=$?
echo "$out" | tail -4 | sed 's/^/    | /'
check "exit 0" '[ $rc = 0 ]'
check "hunted the three 16GB cards" 'grep -q "cards=NVIDIA GeForce RTX 5080|NVIDIA GeForce RTX 4080 SUPER|NVIDIA GeForce RTX 4080" "$STUB/hunt.log"'
check "hunt used the strata profile" 'grep -q "PROFILE=strata" "$STUB/hunt.log"'
check "pod env has FAMILY, MODEL=IQ3_XXS and the key" 'grep -q "POD_ENV=FAMILY=qwen,MODEL=IQ3_XXS,API_KEY=" "$STUB/hunt.log"'
check "pod env asks for the default 128k context" 'grep -q "POD_ENV=.*,CONTEXT=128k" "$STUB/hunt.log"'
check "no other hand tuning in the pod env" '! grep -qE "TUNE=|DRAFT_VOCAB=|conversation-cache" "$STUB/hunt.log"'
check "state records pod fake123" '[ "$(state_pod)" = fake123 ]'
check "memory limit PATCHed from the pod RAM (104 GB -> 97134 MiB)" 'calls | grep "\"PATCH\"" | grep -q "memory-limit-mib=97134"'
check "PATCH keeps the key in the env" 'calls | grep "\"PATCH\"" | grep -q "API_KEY"'
check "ttl set for 3 hours" 'grep -qx "fake123 3" "$STUB/ttl.log"'
check "smoke request went to /v1/messages" 'calls | grep -q "/v1/messages"'
check "prints the strata-cc next step" 'echo "$out" | grep -q "strata-cc"'
check "api key file is private (600)" '[ "$(stat -f %Lp "$STRATA_CONF_DIR/env")" = 600 ]'
check "api key is 48 hex chars" 'grep -qE "^STRATA_API_KEY=[0-9a-f]{48}$" "$STRATA_CONF_DIR/env"'
check "key never printed" '! echo "$out" | grep -qE "[0-9a-f]{48}"'

echo "== T2: strata-on with a RUNNING pod in state: reuses it, no hunt, no second ttl"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
umask 077; echo "STRATA_API_KEY=$(printf 'a%.0s' {1..48})" > "$STRATA_CONF_DIR/env"; umask 022
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$POD_RUNNING],
 "GET fake123.strata.test/v1/models": [$LOADED],
 "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
out=$("$POD" on 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "did not hunt" '[ ! -f "$STUB/hunt.log" ]'
check "did not add a ttl" '[ ! -f "$STUB/ttl.log" ]'
check "says it reused the pod" 'echo "$out" | grep -qi "already running"'

echo "== T3: strata-on with a STOPPED pod: starts it instead of hunting"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
routes <<EOF
{"GET rp.test/v2/pods/fake123": [{"code":200,"body":{"id":"fake123","status":"EXITED","gpu":{"memory":104}}}, $POD_RUNNING],
 "POST rp.test/v2/pods/fake123/action": [{"code":200,"body":{"id":"fake123","status":"STARTING"}}],
 "GET fake123.strata.test/v1/models": [$LOADED],
 "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
out=$("$POD" on 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "sent the start action" 'calls | grep "/action" | grep -q "start"'
check "did not hunt" '[ ! -f "$STUB/hunt.log" ]'
check "set a fresh ttl" 'grep -qx "fake123 3" "$STUB/ttl.log"'

echo "== T4: strata-on with a stopped pod whose GPU is gone: hunts a new one"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"old999"}' > "$STRATA_CONF_DIR/state.json"
routes <<EOF
{"GET rp.test/v2/pods/old999": [{"code":200,"body":{"id":"old999","status":"EXITED","gpu":{"memory":104}}}],
 "POST rp.test/v2/pods/old999/action": [{"code":400,"body":{"status":400,"detail":"There are not enough free GPUs on the host machine"}}],
 "GET rp.test/v2/pods/fake123": [$POD_RUNNING],
 "PATCH rp.test/v2/pods/fake123": [$POD_RUNNING],
 "GET fake123.strata.test/v1/models": [$LOADED],
 "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
out=$("$POD" on 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "hunted" '[ -f "$STUB/hunt.log" ]'
check "state now points at the new pod" '[ "$(state_pod)" = fake123 ]'
check "warns that the old stopped pod still holds its disk" 'echo "$out" | grep -q "old999"'

echo "== T5: strata-on with a terminated pod in state: forgets it and hunts"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"gone1"}' > "$STRATA_CONF_DIR/state.json"
routes <<EOF
{"GET rp.test/v2/pods/gone1": [{"code":404,"body":{"status":404,"detail":"pod not found"}}],
 "GET rp.test/v2/pods/fake123": [$POD_RUNNING],
 "PATCH rp.test/v2/pods/fake123": [$POD_RUNNING],
 "GET fake123.strata.test/v1/models": [$LOADED],
 "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
out=$("$POD" on 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "hunted" '[ -f "$STUB/hunt.log" ]'
check "state now points at the new pod" '[ "$(state_pod)" = fake123 ]'

echo "== T6: strata-on when the hunt finds nothing: fails, writes no state"
setup; export HUNT_FAIL=1
routes <<< '{}'
out=$("$POD" on 2>&1); rc=$?
check "exit non-zero" '[ $rc != 0 ]'
check "no state written" '[ ! -f "$STRATA_CONF_DIR/pods/1.json" ]'
check "no ttl" '[ ! -f "$STUB/ttl.log" ]'
check "says nothing billed" 'echo "$out" | grep -qi "nothing billed"'
unset HUNT_FAIL

echo "== T7: strata-on flags: --hours, --model, --cards reach the hunt and ttl"
setup
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$POD_RUNNING],
 "PATCH rp.test/v2/pods/fake123": [$POD_RUNNING],
 "GET fake123.strata.test/v1/models": [$LOADED],
 "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
out=$("$POD" on --hours 1.5 --model IQ3_S --cards "NVIDIA GeForce RTX 4080" 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "ttl 1.5h" 'grep -qx "fake123 1.5" "$STUB/ttl.log"'
check "model IQ3_S in pod env" 'grep -q "MODEL=IQ3_S," "$STUB/hunt.log"'
check "only the named card" 'grep -qx "cards=NVIDIA GeForce RTX 4080" "$STUB/hunt.log"'

echo "== T8: strata-on: server never loads within the timeout -> non-zero, pod kept, says how to stop it"
setup
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$POD_RUNNING],
 "PATCH rp.test/v2/pods/fake123": [$POD_RUNNING],
 "GET fake123.strata.test/v1/models": [{"code":502,"body":"bad gateway"}]}
EOF
out=$(STRATA_READY_TIMEOUT_S=1 "$POD" on 2>&1); rc=$?
check "exit non-zero" '[ $rc != 0 ]'
check "state kept (pod still billing, ttl still set)" '[ "$(state_pod)" = fake123 ] && [ -f "$STUB/ttl.log" ]'
check "tells how to stop it" 'echo "$out" | grep -q "strata-off"'

echo "== T9: strata-cc with no pod -> clear error naming strata-on"
setup
routes <<< '{}'
out=$("$POD" cc 2>&1); rc=$?
check "exit non-zero" '[ $rc != 0 ]'
check "names strata-on" 'echo "$out" | grep -q "strata-on"'
check "did not start claude" '[ ! -f "$STUB/claude.env" ]'

echo "== T10: strata-cc with a loaded pod -> claude gets Strata's own Claude Code settings"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
umask 077; echo "STRATA_API_KEY=$(printf 'b%.0s' {1..48})" > "$STRATA_CONF_DIR/env"; umask 022
routes <<EOF
{"GET fake123.strata.test/v1/models": [$LOADED]}
EOF
export ANTHROPIC_API_KEY=should-be-removed
out=$("$POD" cc --resume -p "hello there" 2>&1); rc=$?
unset ANTHROPIC_API_KEY
E="$STUB/claude.env"
check "exit 0" '[ $rc = 0 ]'
check "base url is the pod root, no /v1" 'grep -qx "ANTHROPIC_BASE_URL=https://fake123.strata.test" "$E"'
check "auth token is the strata key" 'grep -qx "ANTHROPIC_AUTH_TOKEN=$(printf "b%.0s" {1..48})" "$E"'
check "ANTHROPIC_API_KEY removed" '! grep -q "^ANTHROPIC_API_KEY=" "$E"'
check "every model alias -> served model" '[ $(grep -c "=qwen3.8-flash-next-iq3_xxs$" "$E") = 5 ]'
check "context = served n_ctx" 'grep -qx "CLAUDE_CODE_MAX_CONTEXT_TOKENS=131072" "$E"'
check "output cap = max(4096, ctx/8) = 16384" 'grep -qx "CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384" "$E"'
check "nonessential traffic, telemetry, autoupdater off" 'grep -q "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" "$E" && grep -q "DISABLE_TELEMETRY=1" "$E" && grep -q "DISABLE_AUTOUPDATER=1" "$E"'
check "no CLAUDE_CODE_SIMPLE above 40960" '! grep -q CLAUDE_CODE_SIMPLE "$E"'
check "no thinking budget invented (left to Strata/Claude Code)" '! grep -q MAX_THINKING_TOKENS "$E"'
check "bypass added first, then claude args in order" '[ "$(tr "\n" "|" < "$STUB/claude.args")" = "--dangerously-skip-permissions|--resume|-p|hello there|" ]'

echo "== T10b: strata-cc with the person's own permission flag -> no bypass added"
for flag in "--permission-mode acceptEdits" "--permission-mode=plan" "--dangerously-skip-permissions"; do
  setup
  mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
  umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
  routes <<< "{\"GET fake123.strata.test/v1/models\": [$LOADED]}"
  "$POD" cc $flag >/dev/null 2>&1
  check "[$flag] passed as given, bypass not added twice" '[ "$(tr "\n" " " < "$STUB/claude.args")" = "$flag " ]'
done

echo "== T11: strata-cc on a 32K server -> CLAUDE_CODE_SIMPLE=1 and output 4096 (Strata's rule)"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
umask 077; echo "STRATA_API_KEY=$(printf 'b%.0s' {1..48})" > "$STRATA_CONF_DIR/env"; umask 022
routes <<'EOF'
{"GET fake123.strata.test/v1/models": [{"code":200,"body":{"data":[{"id":"m","status":{"value":"loaded"},"meta":{"n_ctx":32768}}]}}]}
EOF
"$POD" cc >/dev/null 2>&1
check "SIMPLE=1" 'grep -qx "CLAUDE_CODE_SIMPLE=1" "$STUB/claude.env"'
check "output 4096" 'grep -qx "CLAUDE_CODE_MAX_OUTPUT_TOKENS=4096" "$STUB/claude.env"'

echo "== T12: strata-cc while the model is still loading -> non-zero, says wait, no claude"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
routes <<< '{"GET fake123.strata.test/v1/models": [{"code":502,"body":"bad gateway"}]}'
out=$("$POD" cc 2>&1); rc=$?
check "exit non-zero" '[ $rc != 0 ]'
check "did not start claude" '[ ! -f "$STUB/claude.env" ]'
check "points at strata-status" 'echo "$out" | grep -q "strata-status"'

echo "== T13: strata-off terminates, cancels the ttl, clears state"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
routes <<< '{"DELETE rp.test/v2/pods/fake123": [{"code":204,"body":""}]}'
out=$("$POD" off 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "sent DELETE" 'calls | grep -q "\"DELETE\""'
check "cancelled ttl" 'grep -qx -- "--cancel fake123" "$STUB/ttl.log"'
check "state cleared" '[ ! -f "$STRATA_CONF_DIR/pods/1.json" ]'

echo "== T14: strata-off --keep stops (keeps the disk), keeps state, names the idle disk cost"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
routes <<< '{"POST rp.test/v2/pods/fake123/action": [{"code":200,"body":{"id":"fake123","status":"EXITED"}}]}'
out=$("$POD" off --keep 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "sent stop action" 'calls | grep "/action" | grep -q "stop"'
check "no DELETE" '! calls | grep -q "\"DELETE\""'
check "state kept" '[ "$(state_pod)" = fake123 ]'
check "mentions disk still billing" 'echo "$out" | grep -qi "disk"'
check "names the idle price for the profile volume (120 GB at 0.20 = 24/month)" 'echo "$out" | grep -q "24/month"'

echo "== T15: strata-off when the DELETE fails -> non-zero, state kept"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
routes <<< '{"DELETE rp.test/v2/pods/fake123": [{"code":500,"body":{"detail":"boom"}}]}'
out=$("$POD" off 2>&1); rc=$?
check "exit non-zero" '[ $rc != 0 ]'
check "state kept" '[ "$(state_pod)" = fake123 ]'
check "points at gpu-reap" 'echo "$out" | grep -q "gpu-reap"'

echo "== T16: strata-off with no pod -> exit 0, nothing sent"
setup
routes <<< '{}'
out=$("$POD" off 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "no API calls" '[ ! -s "$STUB/calls.log" ]'

echo "== T17: strata-env masks the key; --show-key prints it"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
umask 077; echo "STRATA_API_KEY=$(printf 'c%.0s' {1..48})" > "$STRATA_CONF_DIR/env"; umask 022
routes <<< "{\"GET fake123.strata.test/v1/models\": [$LOADED]}"
out=$("$POD" env 2>&1)
check "masked by default" '! echo "$out" | grep -q "$(printf "c%.0s" {1..48})"'
check "has OpenAI base url with /v1" 'echo "$out" | grep -q "https://fake123.strata.test/v1"'
out=$("$POD" env --show-key 2>&1)
check "--show-key prints it" 'echo "$out" | grep -q "$(printf "c%.0s" {1..48})"'

echo "== T18: strata-extend 2 -> cancels and re-arms the ttl"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
routes <<< '{}'
out=$("$POD" extend 2 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "cancel then new ttl" '[ "$(tr "\n" "|" < "$STUB/ttl.log")" = "--cancel fake123|fake123 2|" ]'

echo "== T19: strata-status prints pod, price, model state and balance"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$POD_RUNNING],
 "GET fake123.strata.test/v1/models": [$LOADED],
 "POST graphql": [{"code":200,"body":{"data":{"myself":{"clientBalance":9.5,"currentSpendPerHr":0.39}}}}]}
EOF
out=$("$POD" status 2>&1); rc=$?
echo "$out" | sed 's/^/    | /'
check "exit 0" '[ $rc = 0 ]'
check "shows RUNNING" 'echo "$out" | grep -q RUNNING'
check "shows price" 'echo "$out" | grep -q "0.39"'
check "shows loaded model and context" 'echo "$out" | grep -q "131072"'
check "shows balance" 'echo "$out" | grep -q "9.5"'
check "balance query authenticates with a Bearer header, key not in the URL" 'grep graphql "$STUB/calls.log" | grep -q "Bearer rp-test-key" && ! grep graphql "$STUB/calls.log" | grep -q "api_key="'

echo "== T20: dispatch by name: strata-on symlink == strata-pod on"
setup
ln -s "$POD" "$T/bin/strata-off"
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
routes <<< '{"DELETE rp.test/v2/pods/fake123": [{"code":204,"body":""}]}'
"$T/bin/strata-off" >/dev/null 2>&1; rc=$?
check "symlink name dispatches" '[ $rc = 0 ] && calls | grep -q "\"DELETE\""'

echo "== T21: the RunPod key is sent only to RunPod, the Strata key only to the pod"
setup
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$POD_RUNNING],
 "PATCH rp.test/v2/pods/fake123": [$POD_RUNNING],
 "GET fake123.strata.test/v1/models": [$LOADED],
 "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
"$POD" on >/dev/null 2>&1
check "no RunPod key to the pod" '! grep "strata.test" "$STUB/calls.log" | grep -q "rp-test-key"'
check "RunPod calls carry the RunPod key" 'grep "rp.test" "$STUB/calls.log" | grep -q "rp-test-key"'

echo "== T22: RUNPOD_API_KEY from the environment wins over .env (it is exported from the shell profile)"
setup
: > "$STRATA_LCR/.env"
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
routes <<< '{"DELETE rp.test/v2/pods/fake123": [{"code":204,"body":""}]}'
RUNPOD_API_KEY=env-key-123 "$POD" off >/dev/null 2>&1; rc=$?
check "works with the key only in the environment" '[ $rc = 0 ]'
check "sent the environment key" 'grep -q "env-key-123" "$STUB/calls.log"'

echo "== T23: no RunPod key anywhere -> non-zero and no request sent"
setup
: > "$STRATA_LCR/.env"
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
routes <<< '{"DELETE rp.test/v2/pods/fake123": [{"code":204,"body":""}]}'
out=$("$POD" off 2>&1); rc=$?
check "exit non-zero" '[ $rc != 0 ]'
check "no request sent" '[ ! -s "$STUB/calls.log" ]'
check "says the key is missing" 'echo "$out" | grep -q "RUNPOD_API_KEY is not set"'

CTX_ROUTES_NEW='"GET rp.test/v2/pods/fake123": ['"$POD_RUNNING"'], "PATCH rp.test/v2/pods/fake123": ['"$POD_RUNNING"'], "POST fake123.strata.test/v1/messages": ['"$MSG_OK"']'
LOADED_64K='{"code":200,"body":{"data":[{"id":"qwen3.8-flash-next-iq3_xxs","status":{"value":"loaded"},"meta":{"n_ctx":65536}}]}}'

echo "== T24: strata-on --context 64k -> new pod asks for 64k"
setup
routes <<< "{$CTX_ROUTES_NEW, \"GET fake123.strata.test/v1/models\": [$LOADED_64K]}"
out=$("$POD" on --context 64k 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "CONTEXT=64k in pod env" 'grep -q "CONTEXT=64k" "$STUB/hunt.log"'
check "no mismatch warning when served = asked" '! echo "$out" | grep -qi "asked for"'

echo "== T25: strata-on --context auto -> no CONTEXT, Strata chooses"
setup
routes <<< "{$CTX_ROUTES_NEW, \"GET fake123.strata.test/v1/models\": [$LOADED]}"
out=$("$POD" on --context auto 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "no CONTEXT in pod env" '! grep -q "CONTEXT=" "$STUB/hunt.log"'

echo "== T26: running pod on 64k, strata-on wants 128k -> PATCH CONTEXT, wait for the restart, keep key + memory cap"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
P64='{"code":200,"body":{"id":"fake123","status":"RUNNING","cost":0.39,"gpu":{"memory":104},"env":{"FAMILY":"qwen","MODEL":"IQ3_XXS","API_KEY":"k","CONTEXT":"64k","STRATA_SET":"memory-limit-mib=97134"}}}'
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$P64],
 "PATCH rp.test/v2/pods/fake123": [$POD_RUNNING],
 "GET fake123.strata.test/v1/models": [$LOADED_64K, {"code":502,"body":"restarting"}, $LOADED],
 "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
out=$("$POD" on 2>&1); rc=$?
echo "$out" | grep -i context | sed 's/^/    | /'
check "exit 0" '[ $rc = 0 ]'
check "PATCH sets CONTEXT=128k" 'calls | grep "\"PATCH\"" | grep -q "CONTEXT[^,]*128k"'
check "PATCH keeps the key and the memory cap" 'calls | grep "\"PATCH\"" | grep -q "API_KEY" && calls | grep "\"PATCH\"" | grep -q "memory-limit-mib=97134"'
check "waited past the old 64k server" 'echo "$out" | grep -q "context 131072"'
check "no hunt, no new ttl" '[ ! -f "$STUB/hunt.log" ] && [ ! -f "$STUB/ttl.log" ]'

echo "== T27: running pod already on 128k -> no PATCH"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
routes <<< "{\"GET rp.test/v2/pods/fake123\": [$POD_RUNNING], \"GET fake123.strata.test/v1/models\": [$LOADED], \"POST fake123.strata.test/v1/messages\": [$MSG_OK]}"
out=$("$POD" on 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "no PATCH" '! calls | grep -q "\"PATCH\""'

echo "== T28: Strata serves less than asked (did not fit) -> warning naming both numbers"
setup
routes <<< "{$CTX_ROUTES_NEW, \"GET fake123.strata.test/v1/models\": [$LOADED_64K]}"
out=$("$POD" on --context 128k 2>&1); rc=$?
check "exit 0 (it still works)" '[ $rc = 0 ]'
check "warns asked 131072, served 65536" 'echo "$out" | grep -q "asked for 131072" && echo "$out" | grep -q "65536"'

echo "== T29: bad --context value -> refused before anything is rented"
setup
routes <<< '{}'
out=$("$POD" on --context lots 2>&1); rc=$?
check "exit non-zero" '[ $rc != 0 ]'
check "no hunt" '[ ! -f "$STUB/hunt.log" ]'

pod_file() { mkdir -p "$STRATA_CONF_DIR/pods"; echo "{\"pod_id\":\"$2\"}" > "$STRATA_CONF_DIR/pods/$1.json"; }
LOADED456='{"code":200,"body":{"data":[{"id":"qwen3.8-flash-next-iq3_xxs","status":{"value":"loaded"},"meta":{"n_ctx":131072}}]}}'
POD456='{"code":200,"body":{"id":"fake456","status":"RUNNING","cost":0.27,"gpu":{"id":"NVIDIA GeForce RTX 4080","memory":64},"env":{"FAMILY":"qwen","MODEL":"IQ3_XXS","API_KEY":"k","CONTEXT":"128k"}}}'

echo "== T30: a legacy state.json becomes pod 1"
setup
mkdir -p "$STRATA_CONF_DIR"; echo '{"pod_id":"fake123"}' > "$STRATA_CONF_DIR/state.json"
routes <<< '{"DELETE rp.test/v2/pods/fake123": [{"code":204,"body":""}]}'
"$POD" off >/dev/null 2>&1; rc=$?
check "exit 0" '[ $rc = 0 ]'
check "deleted the legacy pod" 'calls | grep -q "\"DELETE\""'
check "legacy file moved, nothing left" '[ ! -f "$STRATA_CONF_DIR/state.json" ] && [ ! -f "$STRATA_CONF_DIR/pods/1.json" ]'

echo "== T31: strata-on --name 2 with pod 1 running -> rents a second pod, leaves pod 1 alone"
setup
pod_file 1 fake123
export FAKE_POD_ID=fake456
routes <<EOF
{"GET rp.test/v2/pods/fake456": [$POD456], "PATCH rp.test/v2/pods/fake456": [$POD456],
 "GET fake456.strata.test/v1/models": [$LOADED456], "POST fake456.strata.test/v1/messages": [$MSG_OK]}
EOF
out=$("$POD" on --name 2 2>&1); rc=$?
unset FAKE_POD_ID
check "exit 0" '[ $rc = 0 ]'
check "hunted (did not reuse pod 1)" '[ -f "$STUB/hunt.log" ]'
check "pod named strata-2 on RunPod" 'grep -qx "INSTANCE_NAME=strata-2" "$STUB/hunt.log"'
check "hunt files kept apart (HUNT_RUN=2, own result file)" 'grep -qx "HUNT_RUN=2" "$STUB/hunt.log" && grep -q "RESULT=.*strata-2" "$STUB/hunt.log"'
check "pods/2.json -> fake456" '[ "$(state_pod 2)" = fake456 ]'
check "pods/1.json untouched" '[ "$(state_pod 1)" = fake123 ]'
check "ttl armed for the new pod only" 'grep -qx "fake456 3" "$STUB/ttl.log" && ! grep -q fake123 "$STUB/ttl.log"'
check "no request touched pod 1" '! calls | grep -q fake123'
check "next step names pod 2" 'echo "$out" | grep -q "strata-cc --name 2"'

echo "== T32: STRATA_POD=2 strata-cc -> pod 2"
setup
pod_file 1 fake123; pod_file 2 fake456
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
routes <<< "{\"GET fake456.strata.test/v1/models\": [$LOADED456]}"
STRATA_POD=2 "$POD" cc >/dev/null 2>&1; rc=$?
check "exit 0" '[ $rc = 0 ]'
check "base url is pod 2" 'grep -qx "ANTHROPIC_BASE_URL=https://fake456.strata.test" "$STUB/claude.env"'

echo "== T33: strata-cc --name 2 -p hi -> name consumed, claude gets the rest"
setup
pod_file 2 fake456
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
routes <<< "{\"GET fake456.strata.test/v1/models\": [$LOADED456]}"
"$POD" cc --name 2 -p hi >/dev/null 2>&1
check "pod 2" 'grep -qx "ANTHROPIC_BASE_URL=https://fake456.strata.test" "$STUB/claude.env"'
check "claude args without --name" '[ "$(tr "\n" "|" < "$STUB/claude.args")" = "--dangerously-skip-permissions|-p|hi|" ]'

echo "== T34: strata-status with no name lists every pod"
setup
pod_file 1 fake123; pod_file 2 fake456
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$POD_RUNNING], "GET rp.test/v2/pods/fake456": [$POD456],
 "GET fake123.strata.test/v1/models": [$LOADED], "GET fake456.strata.test/v1/models": [$LOADED456],
 "POST graphql": [{"code":200,"body":{"data":{"myself":{"clientBalance":9.5,"currentSpendPerHr":0.66}}}}]}
EOF
out=$("$POD" status 2>&1); rc=$?
echo "$out" | sed 's/^/    | /'
check "exit 0" '[ $rc = 0 ]'
check "shows pod 1 and pod 2" 'echo "$out" | grep -q "\[1\].*fake123" && echo "$out" | grep -q "\[2\].*fake456"'
check "balance once" '[ "$(echo "$out" | grep -c balance)" = 1 ]'

echo "== T35: strata-off --all ends every pod"
setup
pod_file 1 fake123; pod_file 2 fake456
routes <<< '{"DELETE rp.test/v2/pods/fake123": [{"code":204,"body":""}], "DELETE rp.test/v2/pods/fake456": [{"code":204,"body":""}]}'
out=$("$POD" off --all 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "deleted both" 'calls | grep -q "pods/fake123" && calls | grep -q "pods/fake456"'
check "no pod files left" '[ -z "$(command ls "$STRATA_CONF_DIR/pods" 2>/dev/null)" ]'

echo "== T36: bad pod names are refused"
setup
routes <<< '{}'
for bad in "a/b" "../x" "" "way-too-long-name-over-twenty"; do
  out=$("$POD" on --name "$bad" 2>&1); rc=$?
  check "refused [$bad]" '[ $rc != 0 ] && [ ! -f "$STUB/hunt.log" ]'
done

echo "== T37: RunPod key from ~/.config/strata-runpod/runpod.env when nothing else has it"
setup
: > "$STRATA_LCR/.env"
pod_file 1 fake123
umask 077; echo "RUNPOD_API_KEY=conf-key-77" > "$STRATA_CONF_DIR/runpod.env"; umask 022
routes <<< '{"DELETE rp.test/v2/pods/fake123": [{"code":204,"body":""}]}'
"$POD" off >/dev/null 2>&1; rc=$?
check "exit 0" '[ $rc = 0 ]'
check "used the config key" 'grep -q "conf-key-77" "$STUB/calls.log"'

echo "== T38: strata-pod setup stores the RunPod key privately and never prints it"
setup
routes <<< '{"POST graphql": [{"code":200,"body":{"data":{"myself":{"clientBalance":5,"currentSpendPerHr":0}}}}]}'
out=$(printf 'rp-typed-key-123\n' | "$POD" setup 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "stored in runpod.env" 'grep -qx "RUNPOD_API_KEY=rp-typed-key-123" "$STRATA_CONF_DIR/runpod.env"'
check "mode 600" '[ "$(stat -f %Lp "$STRATA_CONF_DIR/runpod.env")" = 600 ]'
check "key not printed" '! echo "$out" | grep -q "rp-typed-key-123"'
check "checked the key against RunPod" 'grep -q graphql "$STUB/calls.log"'
check "says the balance" 'echo "$out" | grep -q "balance"'

echo "== T39: strata-status --json: every pod, machine readable"
setup
pod_file 1 fake123; pod_file 2 fake456
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$POD_RUNNING], "GET rp.test/v2/pods/fake456": [$POD456],
 "GET fake123.strata.test/v1/models": [$LOADED], "GET fake456.strata.test/v1/models": [{"code":502,"body":"x"}],
 "POST graphql": [{"code":200,"body":{"data":{"myself":{"clientBalance":9.5,"currentSpendPerHr":0.66}}}}]}
EOF
"$POD" status --json > "$STUB/status.json" 2>/dev/null; rc=$?
J="$STUB/status.json"
check "exit 0" '[ $rc = 0 ]'
check "valid JSON with two pods" 'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert len(d[\"pods\"])==2" "$J"'
check "pod 1 loaded, ctx 131072, url" 'python3 -c "import json,sys;p=json.load(open(sys.argv[1]))[\"pods\"][0];assert p[\"name\"]==\"1\" and p[\"loaded\"] and p[\"ctx\"]==131072 and p[\"base_url\"]==\"https://fake123.strata.test\" and p[\"cost\"]==0.39" "$J"'
check "pod 2 not loaded" 'python3 -c "import json,sys;p=json.load(open(sys.argv[1]))[\"pods\"][1];assert p[\"name\"]==\"2\" and not p[\"loaded\"] and p[\"status\"]==\"RUNNING\"" "$J"'
check "balance and spend" 'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert d[\"balance\"]==9.5 and d[\"spend_per_hr\"]==0.66" "$J"'
check "no key in the JSON" '! grep -q "\"x\"" "$J" && ! grep -qi "api_key" "$J"'

echo "== T40: strata-codex: Codex gets Strata's own Codex settings"
setup
pod_file 1 fake123
umask 077; echo "STRATA_API_KEY=$(printf 'd%.0s' {1..48})" > "$STRATA_CONF_DIR/env"; umask 022
routes <<< "{\"GET fake123.strata.test/v1/models\": [$LOADED]}"
"$POD" codex "fix the bug" >/dev/null 2>&1; rc=$?
A="$(tr "\n" " " < "$STUB/codex.args")"
check "exit 0" '[ $rc = 0 ]'
check "key in STRATA_API_KEY" 'grep -qx "STRATA_API_KEY=$(printf "d%.0s" {1..48})" "$STUB/codex.env"'
check "provider strata, responses API, /v1 base" 'echo "$A" | grep -q "model_provider=\"strata\"" && echo "$A" | grep -q "model_providers.strata.base_url=\"https://fake123.strata.test/v1\"" && echo "$A" | grep -q "model_providers.strata.wire_api=\"responses\"" && echo "$A" | grep -q "model_providers.strata.env_key=\"STRATA_API_KEY\""'
check "model and context window" 'echo "$A" | grep -q "model=\"qwen3.8-flash-next-iq3_xxs\"" && echo "$A" | grep -q "model_context_window=131072"'
check "compaction point from Strata formula (131072 -> 66428)" 'echo "$A" | grep -q "model_auto_compact_token_limit=66428"'
check "approval never + workspace-write (Strata harness)" 'echo "$A" | grep -q "approval_policy=\"never\"" && echo "$A" | grep -q "sandbox_mode=\"workspace-write\""'
check "prompt passed last" '[ "$(tail -1 "$STUB/codex.args")" = "fix the bug" ]'
check "key not on the command line" '! grep -q "$(printf "d%.0s" {1..48})" "$STUB/codex.args"'
check "own clean CODEX_HOME by default (a personal ~/.codex can overflow the window)" 'grep -qx "CODEX_HOME=$STRATA_CONF_DIR/codex-home" "$STUB/codex.env" && [ -d "$STRATA_CONF_DIR/codex-home" ]'
STRATA_CODEX_HOME="$T/my-codex" "$POD" codex hi >/dev/null 2>&1
check "STRATA_CODEX_HOME picks your own Codex home" 'grep -qx "CODEX_HOME=$T/my-codex" "$STUB/codex.env"'

echo "== T41: strata-dash --once shows pods and how to connect"
setup
cat > "$T/bin/fake-status" <<'EOF'
#!/bin/bash
cat <<'J'
{"balance": 9.5, "spend_per_hr": 0.82, "pods": [
 {"name": "1", "pod_id": "fake123", "status": "RUNNING", "gpu": "NVIDIA GeForce RTX 5080", "cost": 0.39, "ttl_until": "2026-11-18 23:52",
  "model": "qwen3.8-flash-next-iq3_xxs", "ctx": 131072, "loaded": true, "live_state": "decoding", "live_tok_s": 121.5, "progress": "",
  "base_url": "https://fake123.strata.test"},
 {"name": "2", "pod_id": "fake456", "status": "RUNNING", "gpu": "NVIDIA GeForce RTX 4080", "cost": 0.27, "ttl_until": "2026-11-19 01:00",
  "model": "", "ctx": null, "loaded": false, "live_state": "", "live_tok_s": null, "progress": "Downloading the model files: 30.1 of 76.7 GB",
  "base_url": "https://fake456.strata.test"}]}
J
EOF
chmod +x "$T/bin/fake-status"
out=$(STRATA_STATUS_CMD="$T/bin/fake-status" python3 "$HERE/../bin/strata-dash" --once 2>&1); rc=$?
echo "$out" | sed 's/^/    | /'
check "exit 0" '[ $rc = 0 ]'
check "both pods listed" 'echo "$out" | grep -q fake123 && echo "$out" | grep -q fake456'
check "live speed shown (rounded)" 'echo "$out" | grep -q "122 tok/s"'
check "download progress shown" 'echo "$out" | grep -q "30.1 of 76.7"'
check "claude code command per pod" 'echo "$out" | grep -q "strata-cc" && echo "$out" | grep -q "strata-cc --name 2"'
check "codex command" 'echo "$out" | grep -q "strata-codex"'
check "both endpoint styles" 'echo "$out" | grep -q "https://fake123.strata.test/v1" && echo "$out" | grep -q "ANTHROPIC_BASE_URL"'
check "balance and burn" 'echo "$out" | grep -q "9.5" && echo "$out" | grep -q "0.82"'

echo "== T42: strata-dash --once with no pods says how to start one"
setup
printf '#!/bin/bash\necho '"'"'{"balance": 4.0, "spend_per_hr": 0, "pods": []}'"'"'\n' > "$T/bin/fake-status"; chmod +x "$T/bin/fake-status"
out=$(STRATA_STATUS_CMD="$T/bin/fake-status" python3 "$HERE/../bin/strata-dash" --once 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "names strata-on" 'echo "$out" | grep -q "strata-on"'

echo "== T43: key only in runpod.env (strata-pod setup) reaches the hunt and the auto-terminate timer"
setup
: > "$STRATA_LCR/.env"
mkdir -p "$STRATA_CONF_DIR"; umask 077; echo "RUNPOD_API_KEY=conf-key-43" > "$STRATA_CONF_DIR/runpod.env"; umask 022
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$POD_RUNNING], "PATCH rp.test/v2/pods/fake123": [$POD_RUNNING],
 "GET fake123.strata.test/v1/models": [$LOADED], "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
"$POD" on >/dev/null 2>&1; rc=$?
check "exit 0" '[ $rc = 0 ]'
check "hunt got the key" 'grep -qx "RUNPOD_API_KEY=conf-key-43" "$STUB/hunt.log"'
check "timer got the key (else it cannot terminate the pod)" 'grep -qx "conf-key-43" "$STUB/ttl.key"'

echo "== T44: no RunPod key anywhere -> strata-on says so before hunting"
setup
: > "$STRATA_LCR/.env"
routes <<< '{}'
out=$("$POD" on 2>&1); rc=$?
check "exit non-zero" '[ $rc != 0 ]'
check "says the key is missing" 'echo "$out" | grep -q "RUNPOD_API_KEY is not set"'
check "does not claim a hunt ran" '! echo "$out" | grep -qi "no GPU caught"'
check "no hunt" '[ ! -f "$STUB/hunt.log" ]'

VLLM_MODELS='{"code":200,"body":{"object":"list","data":[{"id":"qwen3.8-flash-next","object":"model","max_model_len":131072}]}}'
PODV='{"code":200,"body":{"id":"fake123","status":"RUNNING","cost":3.38,"gpu":{"id":"NVIDIA RTX PRO 6000 Blackwell Server Edition","count":2,"memory":188},"env":{"VLLM_API_KEY":"k","MAX_MODEL_LEN":"131072"}}}'

echo "== T45: strata-on --engine vllm -> 2x RTX PRO 6000 profile, vLLM command, no Strata env, no memory PATCH"
setup
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$PODV], "PATCH rp.test/v2/pods/fake123": [$PODV],
 "GET fake123.strata.test/v1/models": [{"code":502,"body":"x"}, $VLLM_MODELS],
 "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
out=$("$POD" on --engine vllm 2>&1); rc=$?
echo "$out" | tail -3 | sed 's/^/    | /'
check "exit 0" '[ $rc = 0 ]'
check "profile vllm" 'grep -qx "PROFILE=vllm" "$STUB/hunt.log"'
check "default card RTX PRO 6000" 'grep -qx "cards=NVIDIA RTX PRO 6000 Blackwell Server Edition" "$STUB/hunt.log"'
check "pod env: VLLM_API_KEY and MAX_MODEL_LEN=131072 only" 'grep -q "POD_ENV=VLLM_API_KEY=[0-9a-f]\{48\},MAX_MODEL_LEN=131072$" "$STUB/hunt.log"'
check "no Strata env (FAMILY/MODEL/CONTEXT)" '! grep -qE "POD_ENV=.*(FAMILY|MODEL=IQ|CONTEXT)" "$STUB/hunt.log"'
check "container command is the vllm start script" 'grep -q "^CMD=\[.*vllm serve" "$STUB/hunt.log"'
check "no memory-limit PATCH (Strata-only)" '! calls | grep "\"PATCH\"" | grep -q memory-limit'
check "state records engine vllm" 'python3 -c "import json,sys;assert json.load(open(sys.argv[1]))[\"engine\"]==\"vllm\"" "$STRATA_CONF_DIR/pods/1.json"'
check "ready on vLLM-shaped /v1/models (max_model_len)" 'echo "$out" | grep -q "context 131072"'
check "url uses port 8000" 'calls | grep -q "fake123.strata.test/v1/models"'

echo "== T46: strata-cc on a vLLM pod -> served model id and max_model_len"
setup
mkdir -p "$STRATA_CONF_DIR/pods"; echo '{"pod_id":"fake123","engine":"vllm"}' > "$STRATA_CONF_DIR/pods/1.json"
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
routes <<< "{\"GET fake123.strata.test/v1/models\": [$VLLM_MODELS]}"
"$POD" cc >/dev/null 2>&1; rc=$?
check "exit 0" '[ $rc = 0 ]'
check "model alias = qwen3.8-flash-next" 'grep -qx "ANTHROPIC_MODEL=qwen3.8-flash-next" "$STUB/claude.env"'
check "context from max_model_len" 'grep -qx "CLAUDE_CODE_MAX_CONTEXT_TOKENS=131072" "$STUB/claude.env"'

echo "== T47: running vLLM pod on 262144, strata-on wants 128k -> PATCH MAX_MODEL_LEN=131072"
setup
mkdir -p "$STRATA_CONF_DIR/pods"; echo '{"pod_id":"fake123","engine":"vllm"}' > "$STRATA_CONF_DIR/pods/1.json"
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
PODV262='{"code":200,"body":{"id":"fake123","status":"RUNNING","cost":3.38,"gpu":{"memory":188},"env":{"VLLM_API_KEY":"k","MAX_MODEL_LEN":"262144"}}}'
VM262='{"code":200,"body":{"data":[{"id":"qwen3.8-flash-next","max_model_len":262144}]}}'
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$PODV262], "PATCH rp.test/v2/pods/fake123": [$PODV],
 "GET fake123.strata.test/v1/models": [$VM262, {"code":502,"body":"x"}, $VLLM_MODELS],
 "POST fake123.strata.test/v1/messages": [$MSG_OK]}
EOF
out=$("$POD" on 2>&1); rc=$?
check "exit 0" '[ $rc = 0 ]'
check "PATCH MAX_MODEL_LEN 131072" 'calls | grep "\"PATCH\"" | grep -q "MAX_MODEL_LEN[^,]*131072"'
check "PATCH has no Strata CONTEXT" '! calls | grep "\"PATCH\"" | grep -q "\"CONTEXT"'
check "kept the engine (no hunt)" '[ ! -f "$STUB/hunt.log" ]'

echo "== T48: unknown --engine refused before anything is rented"
setup
routes <<< '{}'
out=$("$POD" on --engine llamacpp 2>&1); rc=$?
check "exit non-zero" '[ $rc != 0 ] && [ ! -f "$STUB/hunt.log" ]'

echo "== T49: --engine vllm --context auto is refused (vLLM needs a number)"
setup
routes <<< '{}'
out=$("$POD" on --engine vllm --context auto 2>&1); rc=$?
check "exit non-zero, no hunt" '[ $rc != 0 ] && [ ! -f "$STUB/hunt.log" ]'

echo "== T50: status --json carries the engine"
setup
mkdir -p "$STRATA_CONF_DIR/pods"; echo '{"pod_id":"fake123","engine":"vllm"}' > "$STRATA_CONF_DIR/pods/1.json"
umask 077; echo "STRATA_API_KEY=x" > "$STRATA_CONF_DIR/env"; umask 022
routes <<EOF
{"GET rp.test/v2/pods/fake123": [$PODV], "GET fake123.strata.test/v1/models": [$VLLM_MODELS],
 "POST graphql": [{"code":200,"body":{"data":{"myself":{"clientBalance":9,"currentSpendPerHr":3.38}}}}]}
EOF
"$POD" status --json > "$STUB/s.json" 2>/dev/null
check "engine vllm, loaded, ctx 131072" 'python3 -c "import json,sys;p=json.load(open(sys.argv[1]))[\"pods\"][0];assert p[\"engine\"]==\"vllm\" and p[\"loaded\"] and p[\"ctx\"]==131072" "$STUB/s.json"'

echo "== T51: strata-status on a pod RunPod no longer has (auto-terminated) -> says so, forgets it"
setup
mkdir -p "$STRATA_CONF_DIR/pods"; echo '{"pod_id":"gone9","ttl_until":"2026-11-18 23:52"}' > "$STRATA_CONF_DIR/pods/1.json"
routes <<< '{"GET rp.test/v2/pods/gone9": [{"code":404,"body":{"status":404,"detail":"pod not found"}}], "POST graphql": [{"code":200,"body":{"data":{"myself":{"clientBalance":8.77,"currentSpendPerHr":0}}}}]}'
out=$("$POD" status 2>&1); rc=$?
echo "$out" | sed 's/^/    | /'
check "exit 0" '[ $rc = 0 ]'
check "says it is gone and nothing bills" 'echo "$out" | grep -qi "gone" && echo "$out" | grep -qi "not billing"'
check "names the auto-terminate time" 'echo "$out" | grep -q "23:52"'
check "says how to start a new one" 'echo "$out" | grep -q "strata-on"'
check "no Strata probe of a dead pod" '! grep -q "strata.test" "$STUB/calls.log"'
check "record cleared" '[ ! -f "$STRATA_CONF_DIR/pods/1.json" ]'

python3 -c 'import glob,shutil,sys; [shutil.rmtree(d) for d in glob.glob(sys.argv[1] + "/t.*")]' "$WORK"
echo
echo "passed $passes, failed $fails"
[ "$fails" = 0 ]
