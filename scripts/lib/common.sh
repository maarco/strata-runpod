#!/usr/bin/env bash

die() {
  printf '✖ %s\n' "$*" >&2
  exit 1
}

info() {
  printf 'ℹ %s\n' "$*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

load_env() {
  # .env holds secrets; PROFILE=<name> layers profiles/<name>.env on top of it.
  # precedence: real environment > profile > .env
  local files=("$ROOT_DIR/.env")
  if [[ -n "${PROFILE:-}" ]]; then
    files+=("$ROOT_DIR/profiles/$PROFILE.env")
    [[ -f "${files[1]}" ]] || die "profile not found: ${files[1]}"
  fi

  # a value already present in the real environment must beat the files, so that
  # `FOO=bar scripts/gpu-instance create` actually overrides them. sourcing
  # alone gets this backwards and silently ignores per-invocation overrides.
  local overrides=() line key f
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" == *=* ]] || continue
      key="${line%%=*}"
      key="${key//[[:space:]]/}"
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      [[ -n "${!key+x}" ]] && overrides+=("$key=${!key}")
    done < "$f"
  done

  set -a
  for f in "${files[@]}"; do
    # shellcheck source=/dev/null
    [[ -f "$f" ]] && source "$f"
  done
  set +a

  local kv
  for kv in "${overrides[@]}"; do
    # shellcheck disable=SC2163  # kv is "NAME=value"; exporting the expanded string is the point
    export "$kv"
  done
}

expand_path() {
  local path="$1"
  if [[ "$path" == \~/* ]]; then
    printf '%s/%s\n' "$HOME" "${path#\~/}"
  else
    printf '%s\n' "$path"
  fi
}

read_public_key() {
  local key_value="${SSH_PUBLIC_KEY:-}"
  if [[ -n "$key_value" ]]; then
    printf '%s\n' "$key_value"
    return
  fi

  local key_path
  key_path="$(expand_path "${SSH_PUBLIC_KEY_PATH:-~/.ssh/id_ed25519.pub}")"
  [[ -f "$key_path" ]] || die "ssh public key not found: $key_path"
  sed -n '1p' "$key_path"
}

json_pick() {
  local expr="$1"
  python3 - "$expr" <<'PY'
import json
import sys

expr = sys.argv[1]
data = json.load(sys.stdin)
for path in expr.split(","):
    cur = data
    ok = True
    for part in path.strip().split("."):
        if not part:
            continue
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            ok = False
            break
    if ok and cur not in (None, ""):
        print(cur)
        sys.exit(0)
sys.exit(1)
PY
}

json_pretty() {
  python3 -m json.tool
}

runtime_file() {
  mkdir -p "$ROOT_DIR/.runtime"
  printf '%s/.runtime/%s\n' "$ROOT_DIR" "$1"
}
