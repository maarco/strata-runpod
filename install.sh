#!/usr/bin/env bash
# Link the strata-* commands into a folder on your PATH (default ~/.local/bin).
#   bash install.sh              PREFIX=/usr/local/bin bash install.sh
# Links point back into this checkout, so `git pull` updates the commands. Never overwrites a real file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local/bin}"
CMDS=(strata-pod strata-on strata-cc strata-codex strata-off strata-status strata-env strata-extend strata-logs)

missing=()
for t in bash curl python3 openssl; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if (( ${#missing[@]} )); then
  echo "missing: ${missing[*]} (install them, then run this again)" >&2
  exit 1
fi

mkdir -p "$PREFIX"
link() {   # link NAME TARGET
  local dest="$PREFIX/$1"
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    echo "refusing to replace $dest: it is a real file, not one of our links. Move it, then run this again." >&2
    return 1
  fi
  ln -sfn "$2" "$dest"
}
for c in "${CMDS[@]}"; do link "$c" "$ROOT/bin/strata-pod"; done
link strata-dash "$ROOT/bin/strata-dash"
chmod +x "$ROOT/bin/strata-pod" "$ROOT/bin/strata-dash" "$ROOT"/scripts/gpu-*

echo "installed ${#CMDS[@]} + 1 commands into $PREFIX"
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "note: $PREFIX is not on your PATH. Add this to ~/.zshrc or ~/.bashrc:  export PATH=\"$PREFIX:\$PATH\"" ;;
esac
for t in claude codex; do
  command -v "$t" >/dev/null 2>&1 || echo "optional: '$t' is not installed (needed only for strata-${t/claude/cc})"
done
echo "next: strata-pod setup     (stores your RunPod API key), then: strata-on"
