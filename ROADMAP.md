# Roadmap

## Phase 1: one user per pod, Strata on a 16 GB card (done)

`strata-on` / `strata-cc` / `strata-codex` / `strata-dash`, named pods, auto-terminate, 128k context.
Measured on an RTX 5080: 110-133 tok/s decode, ~$0.41/hr.

## Phase 2: several users on one server, vLLM on 2x RTX PRO 6000 (Blackwell)

Goal: four or more Claude Code / Codex sessions on one server at 60-80+ tok/s each, with fast prompt reads.

Why: one Strata pod answers one request at a time, and Strata's batching mode buys waiting time, not speed
(its BATCHING.md: 51 tok/s per request at 4 at once on a 4x16 GB split). vLLM batches across users.

### What the research found (2026-11-18)

| setup | 4 users at once, each | source |
|---|---|---|
| 2x RTX PRO 6000, vLLM v0.31.0, NVFP4, TP2, MTP n=3 | 163 tok/s (8: 135, 12: 120, 32: 79) | [SirTificate recipe](https://github.com/SirTificate/qwen3.8-flash-next-nvfp4-2x-rtx-pro-6000) |
| 1x RTX PRO 6000, vLLM, NVFP4/FP8, 64 GB host | ~70 at 8k prompts, ~38 at 32k | [MarcoPizeta bench](https://github.com/MarcoPizeta/flash-next-rtxpro6000-bench) |
| 1x RTX PRO 6000, SGLang, NVFP4, spec k=3 | ~70 per request at 8 at once | [OpenZeka](https://whitepapers.openzeka.com/llm-inference-benchmarks/qwen3-8-flash-next/rtx-pro-6000/nvfp4-sglang-tp1-spec3/) |
| 4 separate 5080 pods (Phase 1) | 110-133 (one user per pod) | measured here |

The 2-GPU numbers used short prompts and 256-token answers; Claude Code sends 26-40k-token prompts, so per-user
speed under real use is unmeasured. vLLM reads prompts ~7x faster than Strata on these cards (cold 26k prompt
~1 s instead of ~6.5 s).

### Cost (RunPod community list price, $1.69 per RTX PRO 6000 per hour)

| usage | 2x RTX PRO 6000 | 4x RTX 5080 pods |
|---|---|---|
| per hour | ~$3.38 | ~$1.64 |
| 24/7, per month | ~$2,470 | ~$1,200 |
| 8 h x 22 workdays | ~$595 | ~$290 |

### RunPod adaptations the recipe needs (open, to verify on the first rented pod)

- The recipe runs with `ipc: host` and `cap_add: SYS_PTRACE` for the per-layer-embedding CPU offload; a RunPod pod
  cannot set either. Plan: `--engram-config '{"cpu_offload": false}'` keeps the tables on the GPUs (vLLM docs: Qwen
  PLE tables are ETP-sharded and honor cpu_offload). Estimate ~63 GB per card, ~28 GB per card left for KV cache.
- `/dev/shm` size on a RunPod pod (vLLM TP workers use it); NCCL has a socket fallback if it is too small.
- The fixed chat template (9.6 KB, NVIDIA Open Model License, so not copied here) reaches the container through
  `profiles/vllm-start.sh`: it downloads it from the recipe's pinned commit, checks its sha256, then `exec vllm serve`.
- Claude Code: vLLM serves `/v1/messages` natively (no LiteLLM); check the streamed reasoning/answer split that
  broke LiteLLM 1.94 (the recipe's `scripts/check_messages_stream.py`).
- Weights: `nvidia/Qwen3.8-Flash-Next-NVFP4` @ `fc694b54`, ungated, 132.7 GB: a 200 GB volume, ~30 min download.
- Auth: `--api-key` (vLLM), same 48-char key scheme as Phase 1.

### Status (2026-11-19)

Built and tested offline, **not yet run on a real pod**:
- `strata-on --engine vllm [--name N] [--context 128k]` rents 2x RTX PRO 6000 (`profiles/vllm.env`), starts
  `profiles/vllm-start.sh` (fetches the recipe's chat template from a pinned commit, checks its sha256, then
  `vllm serve` with the recipe's flags and `cpu_offload: false`), waits on vLLM's `/v1/models`, smoke-tests
  `/v1/messages`. `strata-cc`, `strata-codex`, `strata-status`, `strata-dash` and `strata-off` work the same.
- Tests: `tests/test_strata_pod.sh` (T45-T50) and `tests/test_payload.sh` (the real create request).

Next:
1. One rented test pod (~$3.50 for ~1 h): first boot, `/dev/shm` and the GPU-resident PLE tables are the risks.
2. A concurrency bench with Claude-Code-sized prompts (26-40k tokens) at 1 / 4 / 8 users; decide from that.

## Later

- Auto-terminate that runs on the pod itself (the current timer lives on your computer and stops when it sleeps).
- A RunPod network volume so a new pod skips the 77 GB download (bills ~$0.07/GB/month, pins a datacenter).
- Measure the RTX 4080 / 4080 SUPER fallbacks (estimate 85-100 tok/s; unmeasured).
- Strata's `"anthropic_thinking": "on_request"` for Claude Code helper calls (one side call spent 2,192 tokens).
