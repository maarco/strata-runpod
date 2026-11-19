#!/usr/bin/env bash

runpod_api() {
  local method="$1"
  local path="$2"
  local body_file="${3:-}"

  require_cmd curl
  [[ -n "${RUNPOD_API_KEY:-}" ]] || die "RUNPOD_API_KEY is not set"

  local url="https://api.runpod.io/v2${path}"
  if [[ -n "$body_file" ]]; then
    curl --fail-with-body --silent --show-error \
      -X "$method" "$url" \
      -H "Authorization: Bearer $RUNPOD_API_KEY" \
      -H "Content-Type: application/json" \
      --data-binary "@$body_file"
  else
    curl --fail-with-body --silent --show-error \
      -X "$method" "$url" \
      -H "Authorization: Bearer $RUNPOD_API_KEY"
  fi
}

# runpod injects the key into /root/.ssh/authorized_keys from the PUBLIC_KEY env var
runpod_payload() {
  local public_key="$1"
  python3 - "$public_key" <<'PY'
import json
import os
import sys

public_key = sys.argv[1]

def env(name, default):
    value = os.environ.get(name)
    return value if value not in (None, "") else default

ports = [p.strip() for p in env("RUNPOD_PORTS", "22/tcp,8000/http").split(",") if p.strip()]

# rest v2 (v1 was retired 2026-11-15). one gpu type per create: v2 dropped
# gpuTypeIds lists and gpuTypePriority, so only the first listed type is used.
gpu_types = [g.strip() for g in env("RUNPOD_GPU_TYPE_ID", "NVIDIA RTX PRO 6000 Blackwell Server Edition").split("|") if g.strip()]
if len(gpu_types) > 1:
    sys.stderr.write(f"! runpod v2 takes one gpu type; using {gpu_types[0]!r}, ignoring {gpu_types[1:]}\n")

mount_path = env("RUNPOD_VOLUME_MOUNT", "/workspace")
payload = {
    "name": env("INSTANCE_NAME", "strata"),
    "image": env("RUNPOD_IMAGE", "runpod/pytorch:1.1.0-rc.154-cu1290-torch291-ubuntu2404"),
    "gpu": {"id": gpu_types[0], "count": int(env("RUNPOD_GPU_COUNT", "1"))},
    "cloud": env("RUNPOD_CLOUD_TYPE", "SECURE"),
    "disk": int(env("RUNPOD_CONTAINER_DISK_GB", "100")),
    "ports": ports,
    "env": {
        "PUBLIC_KEY": public_key,
        "HF_TOKEN": env("HF_TOKEN", ""),
        "HF_HOME": mount_path + "/hf",
    },
}
# v2 only sets up sshd when asked; images that run their own server skip it
if any(p.startswith("22/") for p in ports):
    payload["startSsh"] = True

# a network volume survives terminate and moves between pods, so it replaces the
# pod volume entirely. it also pins the pod to the volume's datacenter.
network_volume = env("RUNPOD_NETWORK_VOLUME_ID", "")
if network_volume:
    payload["mounts"] = {"network": [{"volumeId": network_volume, "path": mount_path}]}
else:
    payload["mounts"] = {"persistent": {"size": int(env("RUNPOD_VOLUME_GB", "300")), "path": mount_path}}

# extra container env for images that configure themselves (e.g. strata):
# RUNPOD_POD_ENV="FAMILY=qwen,MODEL=IQ3_XXS"
for pair in env("RUNPOD_POD_ENV", "").split(","):
    if "=" in pair:
        k, v = pair.split("=", 1)
        payload["env"][k.strip()] = v.strip()

min_ram = env("RUNPOD_MIN_RAM_PER_GPU", "")
if min_ram:
    payload["gpu"]["minRamPerGpu"] = int(min_ram)
min_cuda = env("RUNPOD_MIN_CUDA", "")
if min_cuda:
    payload["gpu"]["minCudaVersion"] = min_cuda
cuda = env("RUNPOD_ALLOWED_CUDA", "")
if cuda:
    payload["gpu"]["allowedCudaVersions"] = [c.strip() for c in cuda.split(",") if c.strip()]

data_centers = env("RUNPOD_DATA_CENTER_IDS", "")
if data_centers:
    payload["dataCenterIds"] = [d.strip() for d in data_centers.split(",") if d.strip()]

print(json.dumps(payload, indent=2))
PY
}

provider_create() {
  local dry_run="false"
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run="true"
  fi

  require_cmd python3
  local public_key payload_file
  if [[ "$dry_run" == "true" ]]; then
    local dry_run_key_path
    dry_run_key_path="$(expand_path "${SSH_PUBLIC_KEY_PATH:-~/.ssh/id_ed25519.pub}")"
    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
      public_key="$SSH_PUBLIC_KEY"
    elif [[ -f "$dry_run_key_path" ]]; then
      public_key="$(sed -n '1p' "$dry_run_key_path")"
    else
      public_key="ssh-ed25519 AAAAexample dry-run-key"
    fi
  else
    public_key="$(read_public_key)"
  fi
  payload_file="$(runtime_file runpod-create.json)"
  runpod_payload "$public_key" > "$payload_file"

  if [[ "$dry_run" == "true" ]]; then
    cat "$payload_file"
    return
  fi

  printf '▲ paid gpu create requested\n' >&2
  printf '  provider: runpod\n' >&2
  printf '  gpu:      %sx %s\n' "${RUNPOD_GPU_COUNT:-1}" "${RUNPOD_GPU_TYPE_ID:-NVIDIA RTX PRO 6000 Blackwell Server Edition}" >&2
  printf '  image:    %s\n' "${RUNPOD_IMAGE:-runpod/pytorch:1.1.0-rc.154-cu1290-torch291-ubuntu2404}" >&2
  printf '  disk:     %sGB container / %sGB volume\n' "${RUNPOD_CONTAINER_DISK_GB:-100}" "${RUNPOD_VOLUME_GB:-300}" >&2
  printf '  name:     %s\n' "${INSTANCE_NAME:-strata}" >&2
  printf 'type create to continue: ' >&2
  local confirm
  read -r confirm
  [[ "$confirm" == "create" ]] || die "create cancelled"

  runpod_api POST /pods "$payload_file" | tee "$(runtime_file runpod-last-create.json)" | json_pretty
}

provider_list() {
  # heredoc occupies stdin, so hand the payload over as a file instead of a pipe
  local list_file
  list_file="$(runtime_file runpod-pods.json)"
  runpod_api GET /pods > "$list_file"
  python3 - "$list_file" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)
pods = data if isinstance(data, list) else data.get("pods", [])
pods = [p for p in pods if p.get("status") != "TERMINATED"]
if not pods:
    print("no pods")
    raise SystemExit(0)

print(f"{'id':<20} {'status':<12} {'$/hr':>7}  {'gpu':<34} name")
for pod in pods:
    gpu = pod.get("gpu") or {}
    gpu_name = gpu.get("id") or "?"
    print(
        f"{pod.get('id','?'):<20} "
        f"{pod.get('status','?'):<12} "
        f"{pod.get('cost','?'):>7}  "
        f"{gpu_name[:34]:<34} "
        f"{pod.get('name','')}"
    )
PY
}

provider_status() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "pod_id required"
  runpod_api GET "/pods/$id" | tee "$(runtime_file "runpod-$id.json")" | json_pretty
}

# the rest api leaves publicIp/portMappings empty on plenty of live pods; the
# graphql runtime block is the one that actually has the mapped ssh port.
runpod_graphql() {
  curl --silent --show-error -X POST \
    "https://api.runpod.io/graphql?api_key=$RUNPOD_API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "$1"
}

# echoes "<host> <port>" for the ssh endpoint, or dies with why it is not ready
runpod_ssh_target() {
  local id="$1"
  local status_file gql_file
  status_file="$(runtime_file "runpod-$id.json")"
  gql_file="$(runtime_file "runpod-$id-runtime.json")"

  runpod_api GET "/pods/$id" > "$status_file"
  runpod_graphql '{"query":"query { myself { pods { id desiredStatus runtime { ports { ip isIpPublic privatePort publicPort type } } } } }"}' \
    > "$gql_file" 2>/dev/null || true

  python3 - "$status_file" "$gql_file" "$id" <<'PY'
import json
import sys

status_path, gql_path, pod_id = sys.argv[1], sys.argv[2], sys.argv[3]

with open(status_path) as f:
    pod = json.load(f)

# 1) rest v2 ssh.direct (null until the pod has a public 22/tcp mapping)
direct = (pod.get("ssh") or {}).get("direct") or {}
if direct.get("host") and direct.get("port"):
    print(direct["host"], direct["port"])
    raise SystemExit(0)

# 2) graphql runtime.ports — the reliable source
try:
    with open(gql_path) as f:
        pods = json.load(f)["data"]["myself"]["pods"]
except Exception:
    pods = []

for p in pods:
    if p.get("id") != pod_id:
        continue
    runtime = p.get("runtime")
    if not runtime:
        raise SystemExit(
            f"pod {pod_id} container has not started yet (runtime is null). "
            "give it another minute."
        )
    for entry in runtime.get("ports") or []:
        if entry.get("privatePort") == 22 and entry.get("isIpPublic"):
            print(entry["ip"], entry["publicPort"])
            raise SystemExit(0)
    raise SystemExit(
        f"pod {pod_id} is running but exposes no public port 22. "
        "make sure 22/tcp is in RUNPOD_PORTS."
    )

raise SystemExit(f"pod {pod_id} not found in graphql pod list")
PY
}

provider_ssh() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "pod_id required"
  local target host port key_path user
  target="$(runpod_ssh_target "$id")"
  host="${target%% *}"
  port="${target##* }"
  user="${RUNPOD_SSH_USER:-root}"
  key_path="$(expand_path "${SSH_PRIVATE_KEY_PATH:-~/.ssh/id_ed25519}")"
  if [[ -f "$key_path" ]]; then
    ssh -i "$key_path" -p "$port" "$user@$host"
  else
    ssh -p "$port" "$user@$host"
  fi
}

provider_terminate() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "pod_id required"
  printf '▲ terminate permanently deletes the pod and its volume\n' >&2
  printf '  provider: runpod\n' >&2
  printf '  id:       %s\n' "$id" >&2
  printf 'type confirm to terminate: ' >&2
  local confirm
  read -r confirm
  [[ "$confirm" == "confirm" ]] || die "terminate cancelled"
  runpod_api DELETE "/pods/$id"
  printf '✔ terminated %s\n' "$id" >&2
}
