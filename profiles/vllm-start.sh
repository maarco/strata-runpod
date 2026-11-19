# Runs inside the vLLM container as `bash -c` (strata-on --engine vllm passes this file as the container command).
# Env from strata-on: VLLM_API_KEY, MAX_MODEL_LEN. Everything else is fixed here.
set -euo pipefail
export HF_HOME=/data/hf
export VLLM_USE_DEEP_GEMM=0 VLLM_MOE_USE_DEEP_GEMM=0 VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True CUDA_DEVICE_ORDER=PCI_BUS_ID
REV=fc694b54fb0174e0913e6adf86691ef85a4ead47
TPL=/data/qwen38_flash_next.jinja
# The recipe's fixed chat template (accepts a mid-conversation system message, which Claude Code sends, and
# reasoning_effort high/minimal). NVIDIA Open Model License, so it is fetched, pinned and checked, not vendored.
python3 - "$TPL" <<'PY'
import hashlib, sys, urllib.request
url = ("https://raw.githubusercontent.com/SirTificate/qwen3.8-flash-next-nvfp4-2x-rtx-pro-6000/"
       "a717bc85db5256f8bbda0bcc2ee6551953614816/chat_template/qwen38_flash_next.jinja")
want = "6aeeb9bc1a8b66b3fb7572b66590291ddbfa69d2653b7fa221e3ebf7b23d940d"
data = urllib.request.urlopen(url, timeout=60).read()
got = hashlib.sha256(data).hexdigest()
if got != want:
    sys.exit(f"chat template checksum mismatch: {got}")
open(sys.argv[1], "wb").write(data)
print("chat template ok", flush=True)
PY
# CUDA graph sizes count tokens per decode step: max-num-seqs x (spec tokens + 1) = 32 x 4 = 128 (recipe pitfall 2)
exec vllm serve nvidia/Qwen3.8-Flash-Next-NVFP4 \
  --revision "$REV" --code-revision "$REV" --tokenizer-revision "$REV" \
  --served-model-name qwen3.8-flash-next \
  --host 0.0.0.0 --port 8000 --api-key "$VLLM_API_KEY" \
  --max-model-len "${MAX_MODEL_LEN:-131072}" --max-num-seqs 32 --max-num-batched-tokens 4096 \
  --gpu-memory-utilization 0.95 \
  --tensor-parallel-size 2 --enable-expert-parallel --disable-custom-all-reduce \
  --speculative-config '{"method": "mtp", "num_speculative_tokens": 3, "draft_sample_method": "probabilistic"}' \
  --engram-config '{"cpu_offload": false}' \
  --quantization modelopt --trust-remote-code \
  --reasoning-parser qwen3 --tool-call-parser qwen3_coder --enable-auto-tool-choice \
  --chat-template "$TPL" \
  --no-enable-flashinfer-autotune \
  --compilation-config '{"mode":"NONE","cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[4,8,12,16,20,24,28,32,40,48,56,64,80,96,112,128],"inductor_compile_config":{"triton.autotune_at_compile_time":false}}'
