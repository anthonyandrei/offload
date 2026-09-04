#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/scripts/run-claude-json.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-claude-adapter.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

init_workspace() {
  local workspace="$1"
  mkdir -p "$workspace/.git/info"
  git -C "$workspace" init -q
  git -C "$workspace" config user.name 'Claude adapter test'
  git -C "$workspace" config user.email 'claude-adapter@test.invalid'
  printf 'baseline\n' >"$workspace/owned.txt"
  printf 'frozen\n' >"$workspace/frozen.txt"
  printf '.offload-execution-workspace\n' >"$workspace/.git/info/exclude"
  printf 'offload-execution-workspace-v1\n' >"$workspace/.offload-execution-workspace"
  git -C "$workspace" add owned.txt frozen.txt
  git -C "$workspace" commit -q -m baseline
}

fake_claude="$TMP_ROOT/fake-claude"
cat >"$fake_claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_CLAUDE_RECORD_ARGS:-}" ]; then
  printf '%s\n' "$@" >"$FAKE_CLAUDE_RECORD_ARGS"
fi
case "${1:-}" in
  --version) printf 'claude-fake 1.0\n'; exit 0 ;;
  --help) printf '%s\n' '--output-format --permission-mode --allowedTools --disallowedTools --resume'; exit 0 ;;
esac
case "${FAKE_CLAUDE_MODE:-success}" in
  malformed) printf 'not-json\n'; exit 0 ;;
  cancel) while :; do :; done ;;
  quota) printf 'quota exhausted\n' >&2; exit 75 ;;
esac
printf '%s\n' '{"type":"result","subtype":"success","result":"ok","session_id":"s1"}'
FAKE_CLAUDE
chmod +x "$fake_claude"

catalog="$TMP_ROOT/catalog.json"
cat >"$catalog" <<'CATALOG'
{
  "revision": "test-claude-cat",
  "models": [
    { "id": "claude-3-5-sonnet-20241022", "family_hint": "sonnet", "available": true, "quota_available": true },
    { "id": "claude-3-haiku-20240307", "family_hint": "haiku", "available": true, "quota_available": true }
  ]
}
CATALOG

catalog_request="$TMP_ROOT/catalog-request.json"
cat >"$catalog_request" <<'CATREQ'
{
  "protocol_version": 1,
  "role": "worker",
  "preference": "balanced",
  "effort": "high",
  "required_capabilities": ["structured-output"],
  "policy_revision": "test-policy-1"
}
CATREQ

# 1. Operation catalog test
catalog_output=$(CLAUDE_BIN="$fake_claude" CLAUDE_MODEL_CATALOG="$catalog" "$ADAPTER" --operation catalog --request "$catalog_request")
[ "$(printf '%s' "$catalog_output" | jq -r '.vendor')" = anthropic ] || fail 'catalog vendor is not anthropic'
[ "$(printf '%s' "$catalog_output" | jq -r '.adapter')" = claude ] || fail 'catalog adapter is not claude'
[ "$(printf '%s' "$catalog_output" | jq -r '.protocol_version')" = "1" ] || fail 'catalog protocol_version is not 1'
[ "$(printf '%s' "$catalog_output" | jq -r '.models | length')" -ge 1 ] || fail 'catalog has no models'
pass 'Bash adapter catalog discovery succeeds'

run_adapter() {
  local mode="$1" workspace="$2" cancel_file="${3:-}" prompt="${4:-bounded fake assignment}" record_args="${5:-}"
  local selection="$TMP_ROOT/$mode-selection.json" output="$TMP_ROOT/$mode-result.json" error="$TMP_ROOT/$mode-error.txt"
  jq -n '{protocol_version:1,model_id:"claude-3-5-sonnet-20241022",effort:"high",preference:"balanced",vendor:"anthropic"}' >"$selection"
  set +e
  local cancel_args=()
  if [ -n "$cancel_file" ]; then
    cancel_args=(--cancel-file "$cancel_file")
  fi
  FAKE_CLAUDE_MODE="$mode" FAKE_CLAUDE_RECORD_ARGS="$record_args" CLAUDE_BIN="$fake_claude" CLAUDE_MODEL_CATALOG="$catalog" "$ADAPTER" \
    --operation launch \
    --request "$selection" \
    --output "$output" \
    --error "$error" \
    "${cancel_args[@]}" \
    -- \
    --cd "$workspace" \
    --prompt "$prompt"
  RUN_EXIT=$?
  set -e
  RUN_OUTPUT="$output"
  RUN_ERROR="$error"
}

# 2. Successful launch test with space preservation
workspace="$TMP_ROOT/success with spaces"
init_workspace "$workspace"
record_args="$TMP_ROOT/success-args.txt"
test_prompt='result with spaces and "quotes"'
run_adapter success "$workspace" "" "$test_prompt" "$record_args"
[ "$RUN_EXIT" -eq 0 ] || fail 'success did not return zero'
[ "$(jq -r '.status' "$RUN_OUTPUT")" = success ] || fail 'success status was not success'
[ "$(jq -r '.response' "$RUN_OUTPUT")" = ok ] || fail 'success response was not normalized'
[ "$(jq -r '.session_id' "$RUN_OUTPUT")" = s1 ] || fail 'session id was not normalized'
[ -f "$RUN_ERROR" ] || fail 'error artifact was not written'
grep -qF "$test_prompt" "$record_args" || fail 'prompt argument boundary with spaces was not preserved'
grep -qF "Task" "$record_args" || fail 'Task was not disallowed'
grep -qF "Agent" "$record_args" || fail 'Agent was not disallowed'
[ ! -f "$TMP_ROOT/resource-ledger.json" ] || fail 'private resource ledger was created'
pass 'Bash adapter returns normalized success and preserves argument boundaries'

# 3. Malformed output test
workspace="$TMP_ROOT/malformed"
init_workspace "$workspace"
run_adapter malformed "$workspace"
[ "$RUN_EXIT" -eq 1 ] || fail 'malformed output did not return failure'
pass 'Bash adapter classifies malformed output'

# 4. Cancellation test
cancel_file="$TMP_ROOT/cancel.request"
touch "$cancel_file"
workspace="$TMP_ROOT/cancel"
init_workspace "$workspace"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) pass 'Bash cancellation process-tree test skipped on Windows compatibility runtime' ;;
  *)
    run_adapter cancel "$workspace" "$cancel_file"
    [ "$RUN_EXIT" -eq 130 ] || fail 'cancellation did not return normalized exit code'
    pass 'Bash adapter cancels bounded workers'
    ;;
esac

# 5. Unmarked workspace test
workspace="$TMP_ROOT/unmarked"
init_workspace "$workspace"
rm -f "$workspace/.offload-execution-workspace"
run_adapter success "$workspace"
[ "$RUN_EXIT" -ne 0 ] || fail 'unmarked workspace was accepted'
pass 'Bash adapter fails closed for unmarked workspaces'
