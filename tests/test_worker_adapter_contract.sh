#!/usr/bin/env bash
# Acceptance coverage for the vendor-neutral worker adapter contract.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECKER="$ROOT/scripts/check-worker-adapter.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-adapter-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

[ -f "$ROOT/docs/worker-adapter-contract.md" ] || fail 'worker adapter contract document is missing'
[ -x "$CHECKER" ] || fail 'worker adapter result checker is not executable'

ARTIFACT_ROOT="$TMP_ROOT/artifacts"
mkdir -p "$ARTIFACT_ROOT"
ARTIFACT="$ARTIFACT_ROOT/result.json"
printf '%s\n' '{"ok":true}' > "$ARTIFACT"
ASSIGNMENT="$TMP_ROOT/assignment.json"
RESULT="$TMP_ROOT/result.json"
VALID_RESULT="$TMP_ROOT/valid-result.json"

jq -n --arg worktree "$TMP_ROOT" --arg root "$ARTIFACT_ROOT" '
  {contract_version: 1, assignment_id: "fake-success", request: {prompt: "return the fixture"}, constraints: {
    tools: ["read"], permissions: ["repo.read"], owned_paths: ["src"],
    frozen_paths: ["tests/test_worker_adapter_contract.sh"],
    worktree: {id: "fake-worktree", path: $worktree}, artifact_root: $root,
    cleanup_resource_ids: ["process:fake-success", "worktree:fake-worktree"]
  }}
' > "$ASSIGNMENT"

jq -n --arg artifact "$ARTIFACT" --arg worktree "$TMP_ROOT" --arg root "$ARTIFACT_ROOT" '
  {contract_version: 1, assignment_id: "fake-success", status: "succeeded",
   artifacts: [{path: $artifact, kind: "result", sha256: "not-checked-by-adapter", verified: false}],
   resources: [{type: "process", id: "process:fake-success"}, {type: "worktree", id: "worktree:fake-worktree", path: $worktree}],
   ownership: {resource_ids: ["process:fake-success", "worktree:fake-worktree"]},
   constraint_snapshot: {tools: ["read"], permissions: ["repo.read"], owned_paths: ["src"],
     frozen_paths: ["tests/test_worker_adapter_contract.sh"], worktree: {id: "fake-worktree", path: $worktree},
     artifact_root: $root, cleanup_resource_ids: ["process:fake-success", "worktree:fake-worktree"]},
   model_selection: {provider: "fake", model_id: "fake-model", selection_reason: "fixture"},
   exit: {code: 0, signal: null}, publication: {status: "unpublished"}}
' > "$RESULT"
cp "$RESULT" "$VALID_RESULT"

run_case() {
  local name=$1 expected=$2
  local diagnostic="$TMP_ROOT/diagnostic"
  set +e
  "$CHECKER" --assignment "$ASSIGNMENT" --result "$RESULT" >"$diagnostic" 2>&1
  local actual=$?
  set -e
  [ "$actual" -eq "$expected" ] || fail "$name expected exit $expected, got $actual: $(tr '\n' ' ' < "$diagnostic")"
  pass "$name"
}

run_case 'fake adapter success result satisfies the contract' 0
for status in failed cancelled malformed; do
  cp "$VALID_RESULT" "$RESULT"
  jq --arg status "$status" '.status = $status' "$RESULT" > "$RESULT.tmp"
  mv "$RESULT.tmp" "$RESULT"
  run_case "fake adapter $status result is normalized" 0
done

cp "$VALID_RESULT" "$RESULT"
jq '.status = "failed" | .artifacts = [] | .resources = [] | .ownership.resource_ids = [] | .constraint_snapshot.tools = [] | .constraint_snapshot.permissions = [] | .constraint_snapshot.owned_paths = [] | .constraint_snapshot.frozen_paths = [] | .constraint_snapshot.cleanup_resource_ids = []' "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
run_case 'empty result collections are valid' 0

cp "$VALID_RESULT" "$RESULT"
jq '.constraint_snapshot.tools = "read"' "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
run_case 'scalar result collection is rejected' 2

printf '%s\n' '{not-json' > "$RESULT"
run_case 'malformed adapter output is rejected' 2

cp "$VALID_RESULT" "$RESULT"
jq -n --arg artifact "$TMP_ROOT/outside.json" --arg worktree "$TMP_ROOT" --arg root "$ARTIFACT_ROOT" '
  {contract_version: 1, assignment_id: "fake-success", status: "succeeded", artifacts: [{path: $artifact, kind: "result", sha256: "x", verified: false}],
   resources: [], ownership: {resource_ids: []}, constraint_snapshot: {tools: ["read"], permissions: ["repo.read"], owned_paths: ["src"], frozen_paths: ["tests/test_worker_adapter_contract.sh"], worktree: {id: "fake-worktree", path: $worktree}, artifact_root: $root, cleanup_resource_ids: []}, model_selection: {provider: "fake", model_id: "fake", selection_reason: "fixture"}, exit: {code: 0}, publication: {status: "unpublished"}}
' > "$RESULT"
run_case 'execution-scope artifact violation is rejected' 2

cp "$VALID_RESULT" "$RESULT"
jq --argjson tools '["read", "execute"]' '.constraint_snapshot.tools = $tools' "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
run_case 'tool widening is rejected' 2

cp "$VALID_RESULT" "$RESULT"
jq --argjson cleanup '["process:fake-success", "worktree:fake-worktree", "process:outside"]' '.constraint_snapshot.cleanup_resource_ids = $cleanup' "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
run_case 'cleanup ownership widening is rejected' 2

cp "$VALID_RESULT" "$RESULT"
jq '.resources = [{type: "process", id: "process:outside"}] | .ownership.resource_ids = ["process:fake-success"]' "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
run_case 'unowned resource is rejected' 2

cp "$VALID_RESULT" "$RESULT"
jq --arg outside "$(dirname "$TMP_ROOT")/outside-worktree" '.resources[1].path = $outside' "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
run_case 'resource outside worktree is rejected' 2

cp "$VALID_RESULT" "$RESULT"
jq '.artifacts[0].verified = true' "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
run_case 'verified artifact claim is rejected' 2

cp "$VALID_RESULT" "$RESULT"
jq '.publication.status = "published"' "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
run_case 'adapter publication claim is rejected' 2

pass 'bash fake adapter contract cases completed'
