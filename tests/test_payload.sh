#!/bin/bash
# The real RunPod create request (scripts/gpu-instance create --dry-run) for each profile. Offline, spends nothing.
# Run: bash tests/test_payload.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
fails=0; passes=0
check() { if eval "$2"; then echo "  PASS $1"; passes=$((passes+1)); else echo "  FAIL $1"; fails=$((fails+1)); fi; }
dry() { (cd "$ROOT" && env -u RUNPOD_API_KEY SSH_PUBLIC_KEY="ssh-ed25519 AAAAtest t" "$@" scripts/gpu-instance create --dry-run 2>/dev/null); }
# ok 'python expression on d' : true when the expression holds for the request JSON in $J
ok() { printf '%s' "$J" | python3 -c "import json,sys;d=json.load(sys.stdin);sys.exit(0 if ($1) else 1)" 2>/dev/null; }

echo "== P1: strata profile"
J=$(dry PROFILE=strata RUNPOD_POD_ENV="FAMILY=qwen,MODEL=IQ3_XXS,API_KEY=k,CONTEXT=128k")
check "image ghcr strata" 'ok "d[\"image\"] == \"ghcr.io/niko1221/strata:0.2.16-cuda13\""'
check "one 5080, >=64 GB RAM, cuda >=13" 'ok "d[\"gpu\"] == {\"id\": \"NVIDIA GeForce RTX 5080\", \"count\": 1, \"minRamPerGpu\": 64, \"minCudaVersion\": \"13.0\"}"'
check "port 8080, /data volume" 'ok "d[\"ports\"] == [\"8080/http\"] and d[\"mounts\"][\"persistent\"][\"path\"] == \"/data\""'
check "no start command (the image runs strata itself)" 'ok "\"entrypoint\" not in d and \"cmd\" not in d"'
check "no sshd" 'ok "not d.get(\"startSsh\")"'
check "pod env as given" 'ok "d[\"env\"][\"MODEL\"] == \"IQ3_XXS\" and d[\"env\"][\"CONTEXT\"] == \"128k\""'

echo "== P2: vllm profile with the start script"
CMD=$(python3 -c 'import json,sys;print(json.dumps([open(sys.argv[1]).read()]))' "$ROOT/profiles/vllm-start.sh")
J=$(dry PROFILE=vllm RUNPOD_POD_ENV="VLLM_API_KEY=k,MAX_MODEL_LEN=131072" RUNPOD_CMD_JSON="$CMD")
check "pinned vllm image" 'ok "d[\"image\"].startswith(\"vllm/vllm-openai:v0.31.0@sha256:c1c9f6fd\")"'
check "two RTX PRO 6000" 'ok "d[\"gpu\"][\"id\"] == \"NVIDIA RTX PRO 6000 Blackwell Server Edition\" and d[\"gpu\"][\"count\"] == 2"'
check "entrypoint bash -c" 'ok "d[\"entrypoint\"] == [\"bash\", \"-c\"]"'
check "cmd is the start script (PLE on GPU)" 'ok "len(d[\"cmd\"]) == 1 and \"vllm serve\" in d[\"cmd\"][0] and \"cpu_offload\\\": false\" in d[\"cmd\"][0]"'
check "port 8000, 200 GB /data" 'ok "d[\"ports\"] == [\"8000/http\"] and d[\"mounts\"][\"persistent\"] == {\"size\": 200, \"path\": \"/data\"}"'
check "env carries key and context" 'ok "d[\"env\"][\"VLLM_API_KEY\"] == \"k\" and d[\"env\"][\"MAX_MODEL_LEN\"] == \"131072\""'

echo "== P3: a bad RUNPOD_CMD_JSON is refused"
out=$(cd "$ROOT" && PROFILE=vllm RUNPOD_CMD_JSON='"not a list"' SSH_PUBLIC_KEY=x scripts/gpu-instance create --dry-run 2>&1); rc=$?
check "non-zero" '[ $rc != 0 ]'
check "names the variable" 'echo "$out" | grep -q RUNPOD_CMD_JSON'

echo "== P4: the vllm start script parses and pins everything it depends on"
check "bash syntax" 'bash -n "$ROOT/profiles/vllm-start.sh"'
check "model revision pinned" 'grep -q "REV=fc694b54fb0174e0913e6adf86691ef85a4ead47" "$ROOT/profiles/vllm-start.sh"'
check "template checksum pinned" 'grep -q "6aeeb9bc1a8b66b3fb7572b66590291ddbfa69d2653b7fa221e3ebf7b23d940d" "$ROOT/profiles/vllm-start.sh"'
check "api key required on the server" 'grep -q -- "--api-key \"\$VLLM_API_KEY\"" "$ROOT/profiles/vllm-start.sh"'
check "cuda graph sizes reach max-num-seqs x 4 = 128" 'grep -q -- "--max-num-seqs 32" "$ROOT/profiles/vllm-start.sh" && grep -q "112,128\]" "$ROOT/profiles/vllm-start.sh"'

echo; echo "passed $passes, failed $fails"; [ "$fails" = 0 ]
