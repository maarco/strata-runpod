# strata-runpod

Run [Strata](https://github.com/Niko1221/Strata) (Qwen3.8-Flash-Next, Q3) on a rented RunPod GPU and use it
from your own computer with Claude Code, Codex, or any OpenAI- / Anthropic-style client.

One command rents a 16 GB GPU, starts Strata, caps the spend with an auto-terminate timer and waits until the
model answers. A second command opens Claude Code (or Codex) on it. A small dashboard shows what is running and
how to connect.

Measured on an RTX 5080 pod (2026-11-18): **110-133 tok/s decode**, 1.2k-4.3k tok/s prompt reading, 128k
context, about **$0.41/hr** all in (GPU $0.39 + disk).

## Quick start

You need a RunPod account with credit and an API key (runpod.io > Settings > API Keys, read/write).
macOS or Linux with `bash`, `curl`, `python3`, `openssl`. Claude Code and/or Codex if you want them.

```sh
git clone <this repo> ~/strata-runpod && cd ~/strata-runpod
bash install.sh          # links the strata-* commands into ~/.local/bin
strata-pod setup         # paste your RunPod API key once (or: export RUNPOD_API_KEY=...)
strata-on                # rents a GPU and starts Strata (first start ~25 min: 77 GB download)
strata-dash              # leave this open in a terminal: status + how to connect
strata-cc                # Claude Code on the pod
strata-codex             # Codex on the pod
strata-off               # stop paying
```

`git pull` updates the commands (they are links into this checkout).

## Commands

| command | what it does |
|---|---|
| `strata-pod setup` | store your RunPod key in `~/.config/strata-runpod/runpod.env` (mode 600) and check it |
| `strata-on` | reuse a running pod, restart a stopped one, or rent a new one; caps memory, arms auto-terminate, waits, smoke-tests |
| `strata-on --context 64k` | context size: `64k`, `128k` (default), `256k`, a token count, or `auto` (Strata picks) |
| `strata-on --hours 8` | auto-terminate after 8 h (default 3) |
| `strata-on --cards "NVIDIA GeForce RTX 4080"` | which GPUs to try (default: 5080, 4080 SUPER, 4080, all 16 GB) |
| `strata-cc [claude args]` | Claude Code against the pod |
| `strata-codex [codex args]` | Codex CLI against the pod |
| `strata-dash` | live status window (`--once` prints one snapshot) |
| `strata-status [--json]` | every pod: GPU, price, auto-terminate time, model, last speed, RunPod balance |
| `strata-env [--show-key]` | base URLs and key for other apps |
| `strata-extend 2` | auto-terminate 2 h from now |
| `strata-logs` | the pod's recent container log |
| `strata-off` | terminate the pod (nothing bills afterwards) |
| `strata-off --keep` | stop it but keep the downloaded model; the disk bills $0.20/GB/month while stopped (~$24/month) |

### Several pods at once

Every command takes a leading `--name N`, or set `STRATA_POD=N` once per terminal. No name means pod `1`.

```sh
strata-on --name 2       # a second pod
strata-cc --name 2       # or: export STRATA_POD=2; strata-cc
strata-status            # all pods
strata-off --all
```

One pod serves one request at a time (Strata's drafter), so give each busy Claude Code session its own pod.

### Other apps

`strata-env` prints:

```sh
export ANTHROPIC_BASE_URL=https://<pod>-8080.proxy.runpod.net        # Anthropic Messages API, no /v1
export OPENAI_BASE_URL=https://<pod>-8080.proxy.runpod.net/v1        # OpenAI Chat / Responses API
export ANTHROPIC_AUTH_TOKEN=... OPENAI_API_KEY=...                   # the same Strata key
```

## Settings it uses, and why

- **Engine settings are Strata's defaults.** On a 5080, Strata's own tune said "already fastest". The one
  addition is `memory-limit-mib`, computed per pod: a RunPod container cannot see its RAM limit, and Strata's
  docs name that flag for exactly this case.
- **Claude Code** gets what Strata's `strata connect claude-code` writes: every model alias set to the served
  model, `CLAUDE_CODE_MAX_CONTEXT_TOKENS` = the served context, output cap `max(4096, context/8)`, telemetry and
  the autoupdater off. It runs with `--dangerously-skip-permissions` unless you pass a permission flag: Claude
  Code's auto-mode safety check cannot run against a non-Anthropic server and denies tools.
- **Codex** gets what Strata's harness writes (responses API, context window, compaction point, approval
  `never`, sandbox `workspace-write`) and a clean Codex home in `~/.config/strata-runpod/codex-home`. A personal
  `~/.codex` (memories, global instructions, hooks) can fill the window before the first message;
  `STRATA_CODEX_HOME=~/.codex strata-codex` uses yours anyway.
- **Thinking budget: none.** Strata keeps it opt-in; community runs use 2,048 to 12,000 with no agreement.

## Cost and safety

- Every new pod gets an auto-terminate timer (default 3 h). It runs on **your** computer: if the computer sleeps
  or shuts down, the timer does not fire. `strata-status` shows the end time; `scripts/gpu-reap --dry-run` lists
  everything billing on the account.
- Approximate monthly cost for one 5080 pod: 24/7 ~$300, 8 h x 22 workdays ~$72. Prices are RunPod's and change.
- The API is HTTPS through RunPod's proxy with a random 48-character key; without it every endpoint answers 401.
  The RunPod key is only sent to RunPod, the Strata key only to the pod.

## Troubleshooting

| you see | it means |
|---|---|
| `402 ... balance is too low` | add credit on RunPod |
| `no GPU caught within 30 min` | no 16 GB card free: try later, or `--cards` with more types |
| `502` / `not answering yet` | still downloading or loading: `strata-dash` shows progress |
| Codex: "ran out of room in the context window" | your own Codex home is in use (`STRATA_CODEX_HOME`); unset it |
| Claude Code denies Bash | a permission mode other than bypass was passed; auto mode cannot work here |

## Tests

```sh
bash tests/test_strata_pod.sh      # offline: a fake RunPod/Strata, nothing can rent or spend
bash tests/test_install.sh
bash tests/test-runpod-ssh-target.sh
```

## Credits

Strata is by [Niko1221](https://github.com/Niko1221/Strata); the model is Qwen3.8-Flash-Next by Qwen. This repo only
rents the GPU and wires the clients. See [ROADMAP.md](ROADMAP.md) for the multi-user (Blackwell / vLLM) phase.
