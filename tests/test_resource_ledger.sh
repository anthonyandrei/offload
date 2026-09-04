#!/usr/bin/env bash
# Acceptance tests for the orchestrator-owned resource ledger.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LEDGER="$ROOT/scripts/resource-ledger.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

[ -f "$LEDGER" ] || fail "resource ledger does not exist at $LEDGER"
bash -n "$LEDGER" || fail 'resource ledger does not parse'
command -v jq >/dev/null 2>&1 || fail 'jq is required for resource ledger tests'

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-test-ledger.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

LEDGER_PATH="$TMP_ROOT/ledger.json"
RESOURCE="$TMP_ROOT/resource"
mkdir -p "$RESOURCE"
printf 'offload-resource-v1\n' > "$RESOURCE/.owner"
RESOURCE_CANON=$(cygpath -m "$RESOURCE")

"$LEDGER" init --ledger "$LEDGER_PATH" >/dev/null
pass 'ledger initializes'

"$LEDGER" register \
  --ledger "$LEDGER_PATH" \
  --assignment-id assignment-shell \
  --parent-id parent-shell \
  --resource-type research-workspace \
  --path "$RESOURCE" \
  --owner-marker '.owner=offload-resource-v1' \
  --resource-id resource-shell \
  --state active >/dev/null

record=$(jq -c '.resources[] | select(.resource_id == "resource-shell")' "$LEDGER_PATH")
[ "$(jq -r '.assignment_id' <<<"$record")" = 'assignment-shell' ] || fail 'assignment identity not stored'
[ "$(jq -r '.parent_id' <<<"$record")" = 'parent-shell' ] || fail 'parent identity not stored'
[ "$(jq -r '.resource_type' <<<"$record")" = 'research-workspace' ] || fail 'resource type not stored'
[ "$(jq -r '.path' <<<"$record")" = "$RESOURCE_CANON" ] || fail 'absolute resource path not stored'
[ "$(jq -r '.owner_marker.name + "=" + .owner_marker.value' <<<"$record")" = '.owner=offload-resource-v1' ] || fail 'owner marker not stored'
pass 'resource record stores ownership fields'

"$LEDGER" cleanup --ledger "$LEDGER_PATH" --resource-id resource-shell >/dev/null
[ ! -e "$RESOURCE" ] || fail 'owned resource was not removed'
pass 'owned resource cleanup succeeds'

"$LEDGER" cleanup --ledger "$LEDGER_PATH" --resource-id resource-shell >/dev/null
[ "$(jq -r '.resources[0].state' "$LEDGER_PATH")" = 'removed' ] || fail 'repeat cleanup changed terminal state'
pass 'repeat cleanup is idempotent'

UNOWNED="$TMP_ROOT/unowned"
mkdir -p "$UNOWNED"
printf 'different-owner\n' > "$UNOWNED/.owner"
"$LEDGER" register --ledger "$LEDGER_PATH" --assignment-id assignment-unowned --parent-id parent-shell --resource-type research-workspace --path "$UNOWNED" --owner-marker '.owner=expected-owner' --resource-id resource-unowned --state active >/dev/null
"$LEDGER" cleanup --ledger "$LEDGER_PATH" --resource-id resource-unowned >/dev/null
[ -d "$UNOWNED" ] || fail 'unowned evidence was removed'
[ "$(jq -r '.resources[] | select(.resource_id == "resource-unowned") | .state' "$LEDGER_PATH")" = 'unknown' ] || fail 'unowned resource was not classified unknown'
pass 'unowned resource is retained as unknown'

sleep 30 &
worker_pid=$!
"$LEDGER" register --ledger "$LEDGER_PATH" --assignment-id assignment-worker --parent-id parent-shell --resource-type worker-process --process-id "$worker_pid" --owner-marker 'agy-worker=agy-worker-v1' --resource-id worker-shell --state active >/dev/null
"$LEDGER" cleanup --ledger "$LEDGER_PATH" --resource-id worker-shell >/dev/null
if kill -0 "$worker_pid" 2>/dev/null; then
  kill "$worker_pid" 2>/dev/null || true
  wait "$worker_pid" 2>/dev/null || true
  fail 'owned worker process was not terminated'
fi
pass 'owned worker process is terminated before cleanup completes'

GIT_REPO="$TMP_ROOT/repo"
mkdir -p "$GIT_REPO"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" config user.name 'Ledger Test'
git -C "$GIT_REPO" config user.email 'ledger@example.com'
printf 'base\n' > "$GIT_REPO/base.txt"
git -C "$GIT_REPO" add base.txt
git -C "$GIT_REPO" commit -q -m base
UNKNOWN_WT="$TMP_ROOT/unknown-worktree"
git -C "$GIT_REPO" worktree add --detach -q "$UNKNOWN_WT"
UNKNOWN_WT_CANON=$(cygpath -m "$UNKNOWN_WT")
"$LEDGER" reconcile --ledger "$LEDGER_PATH" --source-repo "$GIT_REPO" >/dev/null
[ "$(jq -r --arg path "$UNKNOWN_WT_CANON" '.resources[] | select(.path == $path) | .state' "$LEDGER_PATH")" = 'unknown' ] || fail 'unknown worktree was not recorded'
[ -d "$UNKNOWN_WT" ] || fail 'unknown worktree was removed'
git -C "$GIT_REPO" worktree remove --force "$UNKNOWN_WT" >/dev/null
pass 'unknown worktree is retained for review'

if "$LEDGER" register --ledger "$TMP_ROOT/inside.json" --assignment-id a --parent-id p --resource-type research-workspace --path "$TMP_ROOT" --owner-marker '.owner=value' >/dev/null 2>&1; then
  fail 'ledger inside resource path was accepted'
fi
pass 'ledger inside resource path is rejected'

printf 'all resource ledger shell tests passed (8 tests)\n'
