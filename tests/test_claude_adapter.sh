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
case "${1:-}" in
  --version) printf 'claude-fake 1.0\n'; exit 0 ;;
  --help) printf '%s\n' '--output-format --permission-mode --allowedTools --disallowedTools --resume'; exit 0 ;;
esac
case "${FAKE_CLAUDE_MODE:-success}" in
  malformed) printf 'not-json\n'; exit 0 ;;
  cancel) while :; do :; done ;;
  scope-failure) printf 'unexpected\n' >unowned.txt ;;
  quota) printf 'quota exhausted\n' >&2; exit 75 ;;
esac
printf '%s\n' '{"type":"result","subtype":"success","result":"ok","session_id":"s1"}'
FAKE_CLAUDE
chmod +x "$fake_claude"

run_adapter() {
  local mode="$1" workspace="$2" cancel_file="${3:-}"
  local assignment="$TMP_ROOT/$mode-assignment.json" output="$TMP_ROOT/$mode-result.json" error="$TMP_ROOT/$mode-error.txt"
  local baseline; baseline=$(git -C "$workspace" rev-parse HEAD)
  jq -n --arg id "test-$mode" --arg prompt 'bounded fake assignment' --arg workdir "$workspace" --arg baseline "$baseline" --arg cancel "$cancel_file" \
    '{schema_version:1,assignment_id:$id,prompt:$prompt,working_directory:$workdir,owned_paths:["owned.txt"],frozen_paths:["frozen.txt"],baseline:$baseline,gate_command:"test -f owned.txt",preference:"balanced",timeout_seconds:10} | if $cancel != "" then .cancel_file=$cancel else . end' >"$assignment"
  set +e
  FAKE_CLAUDE_MODE="$mode" CLAUDE_BIN="$fake_claude" "$ADAPTER" --assignment "$assignment" --output "$output" --error "$error"
  RUN_EXIT=$?
  set -e
  RUN_OUTPUT="$output"
  RUN_ERROR="$error"
}

workspace="$TMP_ROOT/success"
init_workspace "$workspace"
run_adapter success "$workspace"
[ "$RUN_EXIT" -eq 0 ] || fail 'success did not return zero'
[ "$(jq -r '.status' "$RUN_OUTPUT")" = completed ] || fail 'success was not completed'
[ "$(jq -r '.response' "$RUN_OUTPUT")" = ok ] || fail 'success response was not normalized'
[ "$(jq -r '.session_id' "$RUN_OUTPUT")" = s1 ] || fail 'session id was not normalized'
[ "$(jq -r '.resources.process' "$RUN_OUTPUT")" != null ] || fail 'process identity was not reported'
[ -f "$RUN_ERROR" ] || fail 'error artifact was not written'
[ "$(jq -r '[.records[] | select(.resource_type == "process")][0].state' "$TMP_ROOT/resource-ledger.json")" = completed ] || fail 'process was not reconciled'
pass 'Bash adapter returns verified normalized success and ledger records'

workspace="$TMP_ROOT/malformed"
init_workspace "$workspace"
run_adapter malformed "$workspace"
[ "$RUN_EXIT" -eq 1 ] || fail 'malformed output did not return failure'
[ "$(jq -r '.lifecycle' "$RUN_OUTPUT")" = failed ] || fail 'malformed output lifecycle was not failed'
pass 'Bash adapter classifies malformed output'

cancel_file="$TMP_ROOT/cancel.request"
touch "$cancel_file"
workspace="$TMP_ROOT/cancel"
init_workspace "$workspace"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) pass 'Bash cancellation process-tree test skipped on Windows compatibility runtime' ;;
  *)
    run_adapter cancel "$workspace" "$cancel_file"
    [ "$RUN_EXIT" -eq 130 ] || fail 'cancellation did not return normalized exit code'
    [ "$(jq -r '.lifecycle' "$RUN_OUTPUT")" = canceled ] || fail 'cancellation lifecycle was not recorded'
    pass 'Bash adapter cancels bounded workers'
    ;;
esac

workspace="$TMP_ROOT/scope-failure"
init_workspace "$workspace"
run_adapter scope-failure "$workspace"
[ "$RUN_EXIT" -eq 1 ] || fail 'scope failure did not return failure'
[ "$(jq -r '.verification.scope' "$RUN_OUTPUT")" = failed ] || fail 'scope failure was not recorded'
[ "$(jq -r '.verification.gate' "$RUN_OUTPUT")" = not-run ] || fail 'gate ran after scope failure'
pass 'Bash adapter withholds the gate after scope failure'

workspace="$TMP_ROOT/unmarked"
init_workspace "$workspace"
rm -f "$workspace/.offload-execution-workspace"
run_adapter success "$workspace"
[ "$RUN_EXIT" -ne 0 ] || fail 'unmarked workspace was accepted'
pass 'Bash adapter fails closed for unmarked workspaces'
