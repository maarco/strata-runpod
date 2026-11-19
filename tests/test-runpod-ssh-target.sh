#!/usr/bin/env bash
# fixture check for runpod_ssh_target: the one parser that only exercises
# against a live (paid) pod, so it gets tested against canned status json.
# BOTH api paths are stubbed — this must pass with no network and no key.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/common.sh"
source "$ROOT_DIR/scripts/providers/runpod.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# stub the api calls so no network/credentials are needed. runpod_ssh_target
# hits BOTH the rest endpoint and graphql — an unstubbed graphql fires a live
# curl with whatever key is in the environment, and its parser goes untested.
runpod_api() { cat "$FIXTURE"; }
runpod_graphql() { cat "$GQL_FIXTURE"; }
runtime_file() { printf '%s/%s\n' "$tmp" "$1"; }

GQL_NONE='{"data":{"myself":{"pods":[]}}}'

set_fixtures() {
  FIXTURE="$tmp/fixture.json"
  GQL_FIXTURE="$tmp/gql.json"
  printf '%s' "$1" > "$FIXTURE"
  printf '%s' "$2" > "$GQL_FIXTURE"
  # a malformed fixture parses as "no pods" and expect_fail passes for the
  # wrong reason — reject it here instead
  python3 -m json.tool < "$FIXTURE" >/dev/null || die "rest fixture is not valid json"
  python3 -m json.tool < "$GQL_FIXTURE" >/dev/null || die "gql fixture is not valid json"
}

expect_ok() {
  set_fixtures "$1" "$2"
  local got
  got="$(runpod_ssh_target pod123)"
  [[ "$got" == "$3" ]] || { printf '✖ expected %q got %q\n' "$3" "$got" >&2; exit 1; }
  printf '✔ %s -> %s\n' "$4" "$got"
}

expect_fail() {
  set_fixtures "$1" "$2"
  if runpod_ssh_target pod123 >/dev/null 2>&1; then
    printf '✖ expected failure for: %s\n' "$3" >&2
    exit 1
  fi
  printf '✔ %s -> rejected\n' "$3"
}

expect_ok \
  '{"id":"pod123","status":"RUNNING","ssh":{"proxy":null,"direct":{"host":"1.2.3.4","port":40022,"username":"root","command":"ssh"}}}' \
  "$GQL_NONE" \
  '1.2.3.4 40022' \
  'rest v2 ssh.direct'

expect_fail '{"id":"pod123","status":"PROVISIONING","ssh":{"proxy":null,"direct":null}}' \
  "$GQL_NONE" 'no ip yet, pod absent from graphql'

expect_fail '{"id":"pod123","status":"RUNNING","ssh":{"proxy":null,"direct":null}}' \
  "$GQL_NONE" 'port 22 not exposed'

# rest has no direct ssh yet, graphql runtime.ports is authoritative — the real path
expect_ok \
  '{"id":"pod123","status":"RUNNING","ssh":{"proxy":null,"direct":null}}' \
  '{"data":{"myself":{"pods":[{"id":"pod123","desiredStatus":"RUNNING","runtime":{"ports":[{"ip":"5.6.7.8","isIpPublic":true,"privatePort":22,"publicPort":41022,"type":"tcp"}]}}]}}}' \
  '5.6.7.8 41022' \
  'graphql runtime ports'

expect_fail \
  '{"id":"pod123","status":"RUNNING","ssh":{"proxy":null,"direct":null}}' \
  '{"data":{"myself":{"pods":[{"id":"pod123","desiredStatus":"RUNNING","runtime":null}]}}}' \
  'container not started (runtime null)'

expect_fail \
  '{"id":"pod123","status":"RUNNING","ssh":{"proxy":null,"direct":null}}' \
  '{"data":{"myself":{"pods":[{"id":"pod123","desiredStatus":"RUNNING","runtime":{"ports":[{"ip":"10.0.0.5","isIpPublic":false,"privatePort":22,"publicPort":22,"type":"tcp"}]}}]}}}' \
  'port 22 not public'

printf '\nall runpod_ssh_target checks passed\n'
