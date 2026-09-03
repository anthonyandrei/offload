#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

require_file() {
  [ -f "$ROOT/$1" ] || fail "missing $1"
}

require_text() {
  local file=$1
  local pattern=$2
  grep -Fq -- "$pattern" "$ROOT/$file" || fail "$file is missing: $pattern"
}

for file in \
  SKILL.md \
  modes/execution.md \
  modes/repo-research.md \
  modes/web-research.md \
  scripts/make-research-workspace.sh \
  scripts/collect-provenance.sh \
  scripts/cleanup-research-workspace.sh \
  scripts/run-agy-json.sh \
  scripts/extract-structured-output.sh \
  scripts/select-research-outputs.sh \
  scripts/select-research-outputs.ps1 \
  scripts/check-citation-audit.sh; do
  require_file "$file"
done
pass 'router, modes, and helper files exist'

[ "$(wc -l < "$ROOT/SKILL.md")" -lt 500 ] || fail 'SKILL.md is not below 500 lines'
for mode in execution repo-research web-research; do
  require_text SKILL.md "modes/$mode.md"
done
pass 'router stays short and points to every mode'

if rg -n -i 'plan mode[^.]{0,80}(write barrier|prevents? writes?|cannot write)|--add-dir[^.]{0,80}(confine|sandbox|prevents? writes?)|plan-mode[^.]{0,80}(write barrier|prevents? writes?)' \
  "$ROOT" -g '!tests/test_research_modes.sh' -g '!tests/test_workflow_static.ps1' -g '!tests/test_verification_hardening_docs.ps1' -g '!.scratch/**'; then
  fail 'repository still claims plan mode or --add-dir prevents writes'
fi
pass 'stale plan-mode and --add-dir safety claims are absent'

require_text SKILL.md 'web-research'
require_text SKILL.md 'execution'
require_text SKILL.md 'repo-research'
require_text modes/web-research.md 'standard'
require_text modes/web-research.md 'deep'
require_text modes/web-research.md 'synthesizer'
require_text modes/web-research.md 'auditor'
require_text modes/web-research.md 'partial'
require_text modes/web-research.md 'citation'
pass 'web mode documents routing, profiles, synthesis, audit, and partial results'

for script in \
  scripts/make-research-workspace.sh \
  scripts/collect-provenance.sh \
  scripts/cleanup-research-workspace.sh \
  scripts/run-agy-json.sh \
  scripts/extract-structured-output.sh \
  scripts/select-research-outputs.sh \
  scripts/check-citation-audit.sh; do
  bash -n "$ROOT/$script" || fail "$script does not parse"
  [ -x "$ROOT/$script" ] || fail "$script is not executable"
done
pass 'research helpers parse and are executable'

require_text modes/web-research.md 'run-agy-json.sh'
require_text modes/web-research.md 'extract-structured-output.sh'
require_text modes/web-research.md 'select-research-outputs.sh'
require_text modes/web-research.md 'select-research-outputs.ps1'
require_text modes/web-research.md 'independent_angle_count'
require_text modes/web-research.md '.selected_files[]'
require_text modes/web-research.md 'check-citation-audit.sh'
require_text modes/web-research.md 'check-citation-audit.ps1'
require_text modes/web-research.md 'Read `structured_output` from each researcher JSON response'
require_text modes/web-research.md 'Read `structured_output` from the synthesizer JSON response'
require_text modes/web-research.md 'Read `structured_output` from the auditor JSON response'
require_text modes/execution.md 'Read `structured_output` from the JSON response to extract criteria verdicts and quotes'
pass 'web research mode uses the tested agy helpers'

"$ROOT/tests/test_agy_helpers.sh"

fixture="$TMP_ROOT/source"
mkdir -p "$fixture/declared" "$fixture/secret"
printf 'keep\n' > "$fixture/declared/keep.txt"
printf 'exclude\n' > "$fixture/secret/exclude.txt"

# Scoped copying and workspace creation
workspace=$(
  "$ROOT/scripts/make-research-workspace.sh" \
    --source-repo "$fixture" \
    --path declared/keep.txt
)
[ -d "$workspace" ] || fail 'workspace helper did not create a workspace'
[ -f "$workspace/repo/declared/keep.txt" ] || fail 'declared path was not copied'
[ ! -e "$workspace/repo/secret/exclude.txt" ] || fail 'undeclared path was copied'
[ "$workspace" != "$fixture" ] || fail 'workspace points at live repository'
pass 'workspace isolation and scoped copying work'

# Workspace marker creation
marker="$workspace/.offload-research-workspace"
[ -f "$marker" ] || fail 'workspace helper did not create .offload-research-workspace marker'
[ "$(cat "$marker")" = 'offload-research-workspace-v1' ] || fail 'workspace marker does not contain offload-research-workspace-v1'
[ "$(tail -c 1 "$marker" | od -An -t x1 | tr -d '[:space:]')" = '0a' ] || fail 'workspace marker does not end with newline'
pass 'workspace marker created with exact version string'

# Missing declared path warning and continuation
warn_err="$TMP_ROOT/warn.err"
warn_ws=$(
  "$ROOT/scripts/make-research-workspace.sh" \
    --source-repo "$fixture" \
    --path declared/keep.txt \
    --path declared/nonexistent.txt 2>"$warn_err"
)
[ -f "$warn_ws/repo/declared/keep.txt" ] || fail 'existing declared path was not copied when another was missing'
[ -s "$warn_err" ] || fail 'missing declared path did not emit warning on stderr'
pass 'missing declared path emits warning and continues'

# Declared path rejection: parent traversal and absolute paths
if "$ROOT/scripts/make-research-workspace.sh" --source-repo "$fixture" --path '../outside.txt' >/dev/null 2>&1; then
  fail 'workspace helper accepted parent traversal path ..'
fi
if "$ROOT/scripts/make-research-workspace.sh" --source-repo "$fixture" --path 'declared/../../outside.txt' >/dev/null 2>&1; then
  fail 'workspace helper accepted embedded parent traversal path'
fi
if "$ROOT/scripts/make-research-workspace.sh" --source-repo "$fixture" --path '/etc/passwd' >/dev/null 2>&1; then
  fail 'workspace helper accepted absolute path'
fi
pass 'workspace creation rejects traversal and absolute paths'

# Successful cleanup retention (final.md, provenance.json, routing outcomes, disposition, and marker retained)
printf '%s\n' '{"run_id":"run-1","request_summary":"x","selected_mode":"web-research","profile":"standard","deep_trigger":null,"start_time":"2026-01-01T00:00:00Z","end_time":"2026-01-01T00:00:01Z","duration_seconds":1,"scratch_path":"/tmp/run-1","workers":[],"repository_snapshot_paths":[],"final_citations":[],"audit_verdicts":[],"final_status":"success","incomplete_stage_reasons":[]}' > "$workspace/provenance.json"
printf '%s\n' '{"schema_version":1,"attempts":[{"worker_id":"researcher-web-1","role":"researcher","mode":"web-research","attempt":1,"policy_revision":"2026-09-03.1","route":"default","model":"gemini-3.8-flash-high","effort":"high","reason":"Initial dispatch","started_at":"2026-09-03T00:00:00Z","ended_at":"2026-09-03T00:00:01Z","duration_seconds":1,"exit_code":1,"state":"failed","failure_class":"quality","verification_status":"failed","evidence_paths":["evidence/attempt1.json","missing.json","../outside.txt"],"usage":null},{"worker_id":"researcher-web-1","role":"researcher","mode":"web-research","attempt":2,"policy_revision":"2026-09-03.1","route":"default","model":"gemini-3.8-flash-high","effort":"high","reason":"Retry after verification failure","started_at":"2026-09-03T00:00:02Z","ended_at":"2026-09-03T00:00:03Z","duration_seconds":1,"exit_code":0,"state":"completed","failure_class":"none","verification_status":"passed","evidence_paths":["evidence/attempt2.json"],"usage":null}]}' > "$workspace/routing-outcomes.json"
printf '%s\n' 'final result' > "$workspace/final.md"
mkdir -p "$workspace/evidence"
printf '%s\n' 'attempt one evidence' > "$workspace/evidence/attempt1.json"
printf '%s\n' 'attempt two evidence' > "$workspace/evidence/attempt2.json"
printf '%s\n' 'outside evidence' > "$TMP_ROOT/outside.txt"
printf '%s\n' 'raw result' > "$workspace/raw-worker.json"
mkdir -p "$workspace/repo/nested"
printf '%s\n' 'nested data' > "$workspace/repo/nested/data.txt"
"$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$workspace" --status success
[ -f "$workspace/provenance.json" ] || fail 'successful cleanup removed provenance'
[ -f "$workspace/final.md" ] || fail 'successful cleanup removed final result'
[ -f "$workspace/routing-outcomes.json" ] || fail 'successful cleanup removed routing outcomes'
[ -f "$workspace/evidence-disposition.json" ] || fail 'successful cleanup removed evidence disposition'
[ -f "$workspace/.offload-research-workspace" ] || fail 'successful cleanup removed workspace marker'
[ "$(cat "$workspace/.offload-research-workspace")" = 'offload-research-workspace-v1' ] || fail 'successful cleanup corrupted workspace marker'
[ "$(jq -r '.schema_version' "$workspace/evidence-disposition.json")" = '1' ] || fail 'disposition schema version is wrong'
[ "$(jq '.entries | length' "$workspace/evidence-disposition.json")" = '4' ] || fail 'disposition does not cover every evidence path'
[ -n "$(jq -r '.entries[] | [.path, .disposition] | @tsv' "$workspace/evidence-disposition.json")" ] || fail 'disposition entries are empty'
[ "$(jq -r '.entries[] | select(.path == "evidence/attempt1.json") | .disposition' "$workspace/evidence-disposition.json")" = 'pruned' ] || fail 'existing evidence was not marked pruned'
[ -n "$(jq -r '.entries[] | select(.path == "evidence/attempt1.json") | .sha256' "$workspace/evidence-disposition.json")" ] || fail 'existing evidence has no hash'
[ "$(jq -r '.entries[] | select(.path == "missing.json") | .disposition' "$workspace/evidence-disposition.json")" = 'missing' ] || fail 'missing evidence was not marked missing'
[ "$(jq -r '.entries[] | select(.path == "../outside.txt") | .disposition' "$workspace/evidence-disposition.json")" = 'uninspected' ] || fail 'outside evidence was not marked uninspected'
[ "$(cat "$TMP_ROOT/outside.txt")" = 'outside evidence' ] || fail 'outside evidence was modified'
[ ! -e "$workspace/raw-worker.json" ] || fail 'successful cleanup retained raw artifacts'
[ ! -e "$workspace/repo" ] || fail 'successful cleanup retained repo snapshot directory'
routing_before=$(cat "$workspace/routing-outcomes.json")
disposition_before=$(cat "$workspace/evidence-disposition.json")
"$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$workspace" --status success
[ "$(cat "$workspace/routing-outcomes.json")" = "$routing_before" ] || fail 'repeated success changed routing outcomes'
[ "$(cat "$workspace/evidence-disposition.json")" = "$disposition_before" ] || fail 'repeated success changed evidence disposition'
[ "$(jq '.attempts | length' "$workspace/routing-outcomes.json")" = '2' ] || fail 'routing outcomes did not retain both attempts'
[ "$(jq -r '.attempts | sort_by(.attempt) | .[0].verification_status' "$workspace/routing-outcomes.json")" = 'failed' ] || fail 'routing outcomes lost first verification verdict'
[ "$(jq -r '.attempts | sort_by(.attempt) | .[1].verification_status' "$workspace/routing-outcomes.json")" = 'passed' ] || fail 'routing outcomes lost retry verification verdict'
pass 'successful cleanup retains outputs, routing outcomes, disposition, and workspace marker'

# Invalid routing and disposition-write failures retain raw artifacts
invalid_routing_workspace="$TMP_ROOT/invalid-routing-workspace"
mkdir -p "$invalid_routing_workspace"
printf '%s\n' 'offload-research-workspace-v1' > "$invalid_routing_workspace/.offload-research-workspace"
printf '%s\n' '{"schema_version":1,"attempts":"invalid"}' > "$invalid_routing_workspace/routing-outcomes.json"
printf '%s\n' 'raw invalid routing' > "$invalid_routing_workspace/raw-worker.json"
if "$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$invalid_routing_workspace" --status success >/dev/null 2>&1; then
  fail 'cleanup accepted invalid routing record'
fi
[ -f "$invalid_routing_workspace/raw-worker.json" ] || fail 'invalid routing cleanup removed raw artifacts'

manifest_failure_workspace="$TMP_ROOT/manifest-failure-workspace"
mkdir -p "$manifest_failure_workspace/evidence-disposition.json"
printf '%s\n' 'offload-research-workspace-v1' > "$manifest_failure_workspace/.offload-research-workspace"
printf '%s\n' 'raw manifest failure' > "$manifest_failure_workspace/raw-worker.json"
if "$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$manifest_failure_workspace" --status success >/dev/null 2>&1; then
  fail 'cleanup accepted manifest write failure'
fi
[ -f "$manifest_failure_workspace/raw-worker.json" ] || fail 'manifest write failure cleanup removed raw artifacts'
pass 'invalid routing and disposition-write failures retain raw artifacts'

# Partial and failed cleanup retention
workspace_partial=$(
  "$ROOT/scripts/make-research-workspace.sh" \
    --source-repo "$fixture" \
    --path declared/keep.txt
)
printf '%s\n' 'raw partial' > "$workspace_partial/raw-worker.json"
"$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$workspace_partial" --status partial
[ -f "$workspace_partial/raw-worker.json" ] || fail 'partial cleanup removed raw worker artifact'
[ -f "$workspace_partial/repo/declared/keep.txt" ] || fail 'partial cleanup removed repo snapshot file'
pass 'partial cleanup retains raw artifacts and repository snapshot'

workspace_failed=$(
  "$ROOT/scripts/make-research-workspace.sh" \
    --source-repo "$fixture" \
    --path declared/keep.txt
)
printf '%s\n' 'raw failed' > "$workspace_failed/raw-worker.json"
"$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$workspace_failed" --status failed
[ -f "$workspace_failed/raw-worker.json" ] || fail 'failed cleanup removed raw worker artifact'
[ -f "$workspace_failed/repo/declared/keep.txt" ] || fail 'failed cleanup removed repo snapshot file'
pass 'failed cleanup retains raw artifacts and repository snapshot'

# Cleanup refusal for unmarked and unsafe directories
unmarked_dir="$TMP_ROOT/unmarked"
mkdir -p "$unmarked_dir"
printf 'safe\n' > "$unmarked_dir/safe.txt"
if "$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$unmarked_dir" --status success >/dev/null 2>&1; then
  fail 'cleanup accepted unmarked directory on success'
fi
if "$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$unmarked_dir" --status partial >/dev/null 2>&1; then
  fail 'cleanup accepted unmarked directory on partial'
fi
if "$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$unmarked_dir" --status failed >/dev/null 2>&1; then
  fail 'cleanup accepted unmarked directory on failed'
fi
[ -f "$unmarked_dir/safe.txt" ] || fail 'cleanup modified unmarked directory'
pass 'cleanup refuses unmarked directory across all statuses'

invalid_marker_dir="$TMP_ROOT/invalid_marker"
mkdir -p "$invalid_marker_dir"
printf 'wrong-marker-version\n' > "$invalid_marker_dir/.offload-research-workspace"
printf 'safe\n' > "$invalid_marker_dir/safe.txt"
if "$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$invalid_marker_dir" --status success >/dev/null 2>&1; then
  fail 'cleanup accepted invalid workspace marker version'
fi
[ -f "$invalid_marker_dir/safe.txt" ] || fail 'cleanup modified directory with invalid marker'
pass 'cleanup refuses invalid workspace marker version'

git_worktree="$TMP_ROOT/git_worktree"
mkdir -p "$git_worktree/.git"
printf 'offload-research-workspace-v1\n' > "$git_worktree/.offload-research-workspace"
printf 'tracked\n' > "$git_worktree/tracked.txt"
if "$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$git_worktree" --status success >/dev/null 2>&1; then
  fail 'cleanup accepted git worktree root'
fi
[ -f "$git_worktree/tracked.txt" ] || fail 'cleanup modified git worktree directory'
pass 'cleanup refuses git worktree root'

if "$ROOT/scripts/cleanup-research-workspace.sh" --workspace '/' --status success >/dev/null 2>&1; then
  fail 'cleanup accepted filesystem root'
fi
if "$ROOT/scripts/cleanup-research-workspace.sh" --workspace '.' --status success >/dev/null 2>&1; then
  fail 'cleanup accepted process current directory'
fi
if "$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$HOME" --status success >/dev/null 2>&1; then
  fail 'cleanup accepted user home directory'
fi
pass 'cleanup refuses filesystem root, process current directory, and user home directory'

# Provenance collection and validation
prov_out="$TMP_ROOT/provenance-built.json"
"$ROOT/scripts/collect-provenance.sh" \
  --run-id 'run-test-1' \
  --request-summary 'Summary of investigation' \
  --selected-mode 'web-research' \
  --profile 'standard' \
  --start-time '2026-01-01T00:00:00Z' \
  --end-time '2026-01-01T00:00:10Z' \
  --duration-seconds 10.5 \
  --scratch-path '/tmp/scratch-test' \
  --final-status 'success' \
  --workers '[]' \
  --snapshot-paths '[]' \
  --final-citations '[]' \
  --audit-verdicts '[]' \
  --incomplete-stage-reasons '[]' \
  --output "$prov_out"

[ -f "$prov_out" ] || fail 'collect-provenance did not create output file'
[ "$(tail -c 1 "$prov_out" | od -An -t x1 | tr -d '[:space:]')" = '0a' ] || fail 'collect-provenance output missing trailing newline'
[ "$(jq -r '.run_id' "$prov_out")" = 'run-test-1' ] || fail 'collect-provenance corrupted run_id'
[ "$(jq -r '.request_summary' "$prov_out")" = 'Summary of investigation' ] || fail 'collect-provenance corrupted request_summary'
[ "$(jq -r '.selected_mode' "$prov_out")" = 'web-research' ] || fail 'collect-provenance corrupted selected_mode'
[ "$(jq -r '.profile' "$prov_out")" = 'standard' ] || fail 'collect-provenance corrupted profile'
[ "$(jq '.deep_trigger' "$prov_out")" = 'null' ] || fail 'collect-provenance deep_trigger is not null when absent'
[ "$(jq '.duration_seconds' "$prov_out")" = '10.5' ] || fail 'collect-provenance duration_seconds is not numeric'
[ "$(jq -r '.final_status' "$prov_out")" = 'success' ] || fail 'collect-provenance corrupted final_status'
for req_key in run_id request_summary selected_mode profile deep_trigger start_time end_time duration_seconds scratch_path workers repository_snapshot_paths final_citations audit_verdicts final_status incomplete_stage_reasons; do
  jq -e "has(\"$req_key\")" "$prov_out" >/dev/null || fail "collect-provenance missing required field: $req_key"
done
pass 'collect-provenance builds valid schema record with all required fields'

cits_file="$TMP_ROOT/citations-input.json"
printf '%s\n' '[{"url":"https://example.com","title":"Example Citation"}]' > "$cits_file"
prov_file_array="$TMP_ROOT/prov-file-array.json"
"$ROOT/scripts/collect-provenance.sh" \
  --run-id 'run-array-test' \
  --request-summary 'Array test summary' \
  --selected-mode 'repo-research' \
  --profile 'deep' \
  --deep-trigger 'threshold_exceeded' \
  --start-time '2026-01-01T00:00:00Z' \
  --end-time '2026-01-01T00:00:05Z' \
  --duration-seconds 5 \
  --scratch-path '/tmp/scratch' \
  --final-status 'partial' \
  --final-citations "$cits_file" \
  --output "$prov_file_array"
[ "$(jq '.final_citations | length' "$prov_file_array")" -eq 1 ] || fail 'collect-provenance did not load array from file path'
[ "$(jq -r '.final_citations[0].url' "$prov_file_array")" = 'https://example.com' ] || fail 'collect-provenance preserved array element url'
[ "$(jq -r '.deep_trigger' "$prov_file_array")" = 'threshold_exceeded' ] || fail 'collect-provenance preserved explicit deep_trigger string'
pass 'collect-provenance accepts JSON array from file path and explicit deep_trigger'

"$ROOT/scripts/collect-provenance.sh" --validate "$prov_out"
pass 'collect-provenance --validate passes for valid record'

if "$ROOT/scripts/collect-provenance.sh" --run-id r1 --request-summary s --start-time t1 --end-time t2 --duration-seconds 1 --scratch-path p --final-status success --selected-mode invalid-mode >/dev/null 2>&1; then
  fail 'collect-provenance accepted invalid selected_mode'
fi
if "$ROOT/scripts/collect-provenance.sh" --run-id r1 --request-summary s --start-time t1 --end-time t2 --duration-seconds 1 --scratch-path p --final-status success --profile invalid-profile >/dev/null 2>&1; then
  fail 'collect-provenance accepted invalid profile'
fi
if "$ROOT/scripts/collect-provenance.sh" --run-id r1 --request-summary s --start-time t1 --end-time t2 --duration-seconds 1 --scratch-path p --final-status invalid-status >/dev/null 2>&1; then
  fail 'collect-provenance accepted invalid final_status'
fi
if "$ROOT/scripts/collect-provenance.sh" --run-id r1 --request-summary s --start-time t1 --end-time t2 --scratch-path p --final-status success --duration-seconds -5 >/dev/null 2>&1; then
  fail 'collect-provenance accepted negative duration_seconds'
fi

bad_prov="$TMP_ROOT/bad-prov.json"
printf '%s\n' '{"run_id":"r1","profile":"standard"}' > "$bad_prov"
if "$ROOT/scripts/collect-provenance.sh" --validate "$bad_prov" >/dev/null 2>&1; then
  fail 'collect-provenance --validate accepted record missing required fields'
fi
pass 'collect-provenance rejects invalid enum values, negative duration, and incomplete records'

# Routing provenance fixture verification (Issue #13)
require_file 'tests/fixtures/routing-worker.json'

python3 -c '
import json, re, sys

with open("modes/web-research.md", "r", encoding="utf-8") as f:
    content = f.read()

blocks = re.findall(r"```json\r?\n([\s\S]*?)\r?\n\s*```", content)
doc_block = None
for b in blocks:
    if "researcher-web-1" in b:
        doc_block = b.strip()
        break

if not doc_block:
    sys.stderr.write("documented researcher-web-1 json block missing in modes/web-research.md\n")
    sys.exit(1)

doc_data = json.loads(doc_block)
with open("tests/fixtures/routing-worker.json", "r", encoding="utf-8") as f:
    fix_data = json.load(f)

if doc_data != fix_data:
    sys.stderr.write("documented json does not match tests/fixtures/routing-worker.json\n")
    sys.exit(1)
' || fail 'documented JSON example in modes/web-research.md does not match tests/fixtures/routing-worker.json'
pass 'documented worker example in modes/web-research.md matches tests/fixtures/routing-worker.json'

prov_fixture_out="$TMP_ROOT/prov-fixture-built.json"
"$ROOT/scripts/collect-provenance.sh" \
  --run-id 'run-fixture-test' \
  --request-summary 'Routing fixture verification' \
  --selected-mode 'web-research' \
  --profile 'standard' \
  --start-time '2026-01-01T00:00:00Z' \
  --end-time '2026-01-01T00:05:00Z' \
  --duration-seconds 300 \
  --scratch-path '/tmp/scratch-fixture' \
  --final-status 'success' \
  --workers "[$(cat "$ROOT/tests/fixtures/routing-worker.json")]" \
  --output "$prov_fixture_out"

[ -f "$prov_fixture_out" ] || fail 'collect-provenance did not create output for fixture'
"$ROOT/scripts/collect-provenance.sh" --validate "$prov_fixture_out" || fail 'collect-provenance --validate failed on fixture record'

[ "$(jq -r '.workers[0].id' "$prov_fixture_out")" = 'researcher-web-1' ] || fail 'fixture worker id corrupted'
[ "$(jq '.workers[0].routing.schema_version' "$prov_fixture_out")" -eq 1 ] || fail 'fixture worker schema_version corrupted'
[ "$(jq '.workers[0].routing.attempts | length' "$prov_fixture_out")" -eq 2 ] || fail 'fixture worker attempts count is not 2'
[ "$(jq -r '.workers[0].routing.attempts[0].worker_id' "$prov_fixture_out")" = 'researcher-web-1' ] || fail 'attempt 1 worker_id mismatch'
[ "$(jq -r '.workers[0].routing.attempts[1].worker_id' "$prov_fixture_out")" = 'researcher-web-1' ] || fail 'attempt 2 worker_id mismatch'
[ "$(jq '.workers[0].routing.attempts[0].attempt' "$prov_fixture_out")" -eq 1 ] || fail 'attempt 1 number mismatch'
[ "$(jq '.workers[0].routing.attempts[1].attempt' "$prov_fixture_out")" -eq 2 ] || fail 'attempt 2 number mismatch'
[ "$(jq -r '.workers[0].accepted_attempt' "$prov_fixture_out")" -eq 2 ] || fail 'accepted_attempt does not select attempt 2'
[ "$(jq -r '.workers[0].output' "$prov_fixture_out")" = 'workspace/researcher-web-1.attempt2.json' ] || fail 'worker output does not select attempt 2 artifact'
[ "$(jq -r '.workers[0].routing.attempts[0].evidence_paths[0]' "$prov_fixture_out")" = 'workspace/researcher-web-1.attempt1.json' ] || fail 'attempt 1 evidence path is not attempt-specific'
[ "$(jq -r '.workers[0].routing.attempts[1].evidence_paths[0]' "$prov_fixture_out")" = 'workspace/researcher-web-1.attempt2.json' ] || fail 'attempt 2 evidence path is not attempt-specific'
[ "$(jq -r '.workers[0].routing.attempts[0].evidence_paths[1]' "$prov_fixture_out")" = 'workspace/researcher-web-1.attempt1.err' ] || fail 'attempt 1 error path is not attempt-specific'
[ "$(jq -r '.workers[0].routing.attempts[1].evidence_paths[1]' "$prov_fixture_out")" = 'workspace/researcher-web-1.attempt2.err' ] || fail 'attempt 2 error path is not attempt-specific'
[ "$(jq -r '.workers[0].routing.attempts[0].evidence_paths[0]' "$prov_fixture_out")" != "$(jq -r '.workers[0].routing.attempts[1].evidence_paths[0]' "$prov_fixture_out")" ] || fail 'retry reused the attempt 1 evidence path'

for req_att_field in worker_id role mode attempt policy_revision route model effort reason started_at ended_at duration_seconds exit_code state failure_class verification_status evidence_paths usage; do
  jq -e ".workers[0].routing.attempts[0] | has(\"$req_att_field\")" "$prov_fixture_out" >/dev/null || fail "attempt 1 missing field: $req_att_field"
  jq -e ".workers[0].routing.attempts[1] | has(\"$req_att_field\")" "$prov_fixture_out" >/dev/null || fail "attempt 2 missing field: $req_att_field"
done
pass 'collect-provenance validates documented fixture and preserves all attempt fields under stable identity'

# Two fake dispatches using the documented Bash naming convention must not overwrite attempt 1.
retry_fake_bin="$TMP_ROOT/retry-fake-bin"
mkdir -p "$retry_fake_bin"
cat > "$retry_fake_bin/agy" <<'FAKE_RETRY_AGY'
#!/usr/bin/env bash
set -euo pipefail
tag="${FAKE_AGY_TAG:?FAKE_AGY_TAG is required}"
printf 'fake stderr %s\n' "$tag" >&2
printf '{"status":"success","response":"%s","structured_output":{"attempt":"%s"}}\n' "$tag" "$tag"
FAKE_RETRY_AGY
chmod +x "$retry_fake_bin/agy"

retry_dir="$TMP_ROOT/retry-artifacts"
retry_worker_id='researcher-web-1'
retry_attempt1_output="$retry_dir/$retry_worker_id.attempt1.json"
retry_attempt1_error="$retry_dir/$retry_worker_id.attempt1.err"
retry_attempt2_output="$retry_dir/$retry_worker_id.attempt2.json"
retry_attempt2_error="$retry_dir/$retry_worker_id.attempt2.err"
FAKE_AGY_TAG=attempt1 PATH="$retry_fake_bin:$PATH" \
  "$ROOT/scripts/run-agy-json.sh" --role researcher \
  --output "$retry_attempt1_output" --error "$retry_attempt1_error" -- -p 'attempt 1'
retry_attempt1_output_hash=$(sha256sum "$retry_attempt1_output" | awk '{print $1}')
retry_attempt1_error_hash=$(sha256sum "$retry_attempt1_error" | awk '{print $1}')
FAKE_AGY_TAG=attempt2 PATH="$retry_fake_bin:$PATH" \
  "$ROOT/scripts/run-agy-json.sh" --role researcher \
  --output "$retry_attempt2_output" --error "$retry_attempt2_error" -- -p 'attempt 2'
[ "$(sha256sum "$retry_attempt1_output" | awk '{print $1}')" = "$retry_attempt1_output_hash" ] || fail 'second Bash dispatch changed attempt 1 output'
[ "$(sha256sum "$retry_attempt1_error" | awk '{print $1}')" = "$retry_attempt1_error_hash" ] || fail 'second Bash dispatch changed attempt 1 error'
[ "$(jq -r '.structured_output.attempt' "$retry_attempt1_output")" = attempt1 ] || fail 'Bash attempt 1 artifact does not contain attempt 1 payload'
[ "$(jq -r '.structured_output.attempt' "$retry_attempt2_output")" = attempt2 ] || fail 'Bash attempt 2 artifact does not contain attempt 2 payload'
retry_record="$retry_dir/routing.json"
printf '{"run_id":"retry-run","request_summary":"retry artifact test","selected_mode":"web-research","profile":"standard","deep_trigger":null,"start_time":"2026-01-01T00:00:00Z","end_time":"2026-01-01T00:05:00Z","duration_seconds":300,"scratch_path":"%s","workers":[{"id":"%s","role":"researcher","status":"completed","output":"%s","accepted_attempt":2,"routing":{"schema_version":1,"attempts":[{"worker_id":"%s","role":"researcher","mode":"web-research","attempt":1,"policy_revision":"2026-09-03.1","route":"default","model":"gemini-3.8-flash-high","effort":"high","reason":"Initial default dispatch","started_at":"2026-01-01T00:00:00Z","ended_at":"2026-01-01T00:01:00Z","duration_seconds":60,"exit_code":0,"state":"completed","failure_class":"none","verification_status":"passed","evidence_paths":["%s","%s"],"usage":null},{"worker_id":"%s","role":"researcher","mode":"web-research","attempt":2,"policy_revision":"2026-09-03.1","route":"default","model":"gemini-3.8-flash-high","effort":"high","reason":"Retry after verification failure","started_at":"2026-01-01T00:02:00Z","ended_at":"2026-01-01T00:03:00Z","duration_seconds":60,"exit_code":0,"state":"completed","failure_class":"none","verification_status":"passed","evidence_paths":["%s","%s"],"usage":null}]}}],"repository_snapshot_paths":[],"final_citations":[],"audit_verdicts":[],"final_status":"success","incomplete_stage_reasons":[]}\n' \
  '/tmp/retry-artifacts' "$retry_worker_id" "$retry_attempt2_output" "$retry_worker_id" "$retry_attempt1_output" "$retry_attempt1_error" "$retry_worker_id" "$retry_attempt2_output" "$retry_attempt2_error" > "$retry_record"
"$ROOT/scripts/collect-provenance.sh" --validate "$retry_record" || fail 'Bash retry routing record failed validation'
pass 'Bash attempt-specific artifacts preserve attempt 1 and validate explicit accepted attempt'

bare_worker='{"id":"researcher-web-1","role":"researcher","status":"completed","output":"workspace/researcher-web-1.json","routing":{"worker_id":"researcher-web-1","role":"researcher","mode":"web-research","attempt":1,"policy_revision":"2026-09-03.1","route":"default","model":"gemini-3.8-flash-high","effort":"high","reason":"Initial default dispatch","started_at":"2026-09-03T00:00:00Z","ended_at":"2026-09-03T00:01:30Z","duration_seconds":90.0,"exit_code":0,"state":"completed","failure_class":"none","verification_status":"passed","evidence_paths":[],"usage":null}}'
bare_prov="$TMP_ROOT/bare-prov.json"
printf '{"run_id":"r1","request_summary":"s","selected_mode":"web-research","profile":"standard","deep_trigger":null,"start_time":"2026-01-01T00:00:00Z","end_time":"2026-01-01T00:05:00Z","duration_seconds":300,"scratch_path":"/tmp/scratch","workers":[%s],"repository_snapshot_paths":[],"final_citations":[],"audit_verdicts":[],"final_status":"success","incomplete_stage_reasons":[]}\n' "$bare_worker" > "$bare_prov"

if "$ROOT/scripts/collect-provenance.sh" --validate "$bare_prov" >/dev/null 2>&1; then
  fail 'collect-provenance --validate accepted bare-attempt shape'
fi
if "$ROOT/scripts/collect-provenance.sh" --run-id r1 --request-summary s --selected-mode web-research --profile standard --start-time 2026-01-01T00:00:00Z --end-time 2026-01-01T00:05:00Z --duration-seconds 300 --scratch-path /tmp/scratch --final-status success --workers "[$bare_worker]" >/dev/null 2>&1; then
  fail 'collect-provenance build mode accepted bare-attempt shape'
fi
pass 'collect-provenance rejects previously documented bare-attempt shape in validation and build mode'

# Research synthesis selection tests (Issue #15)
selection_dir="$TMP_ROOT/research-selection"
mkdir -p "$selection_dir"
printf '%s\n' '{"response":"official prose","structured_output":{"run_id":"selection-run","angle_id":"official","status":"success","question":"What does the official angle establish?","findings":[{"claim":"official finding","source_urls":["https://example.com/official"]}]}}' > "$selection_dir/official.json"
printf '%s\n' '{"response":"independent prose","structured_output":{"run_id":"selection-run","angle_id":"independent","status":"success","question":"What does the independent angle establish?","findings":[{"claim":"independent finding","source_urls":["https://example.com/independent"]}]}}' > "$selection_dir/independent.json"
printf '%s\n' '{"response":"stale prose","structured_output":{"run_id":"selection-run","angle_id":"retry-old","status":"success","question":"What does the old retry establish?","findings":[{"claim":"stale retry finding","source_urls":["https://example.com/retry-old"]}]}}' > "$selection_dir/retry-old.json"
printf '%s\n' '{"response":"verified prose","structured_output":{"run_id":"selection-run","angle_id":"retry-new","status":"success","question":"What does the verified retry establish?","findings":[{"claim":"verified retry finding","source_urls":["https://example.com/retry-new"]}]}}' > "$selection_dir/retry-new.json"
printf '%s\n' '{"response":"unverified prose","structured_output":{"run_id":"selection-run","angle_id":"unverified","status":"success","question":"What does the unverified angle establish?","findings":[{"claim":"unverified finding","source_urls":["https://example.com/unverified"]}]}}' > "$selection_dir/unverified.json"

selection_primary="$selection_dir/primary-routing.json"
jq -n \
  --arg official 'official.json' \
  --arg independent 'independent.json' \
  --arg exhausted 'exhausted.json' \
  '{workers:[
    {id:"researcher-official",role:"researcher",status:"completed",output:$official,accepted_attempt:1,routing:{schema_version:1,attempts:[{worker_id:"researcher-official",attempt:1,state:"completed",verification_status:"passed",exit_code:0,evidence_paths:[$official,"official.err"]}]}},
    {id:"researcher-independent",role:"researcher",status:"completed",output:$independent,accepted_attempt:1,routing:{schema_version:1,attempts:[{worker_id:"researcher-independent",attempt:1,state:"completed",verification_status:"passed",exit_code:0,evidence_paths:[$independent,"independent.err"]}]}},
    {id:"researcher-exhausted",role:"researcher",status:"failed",output:$exhausted,accepted_attempt:1,routing:{schema_version:1,attempts:[{worker_id:"researcher-exhausted",attempt:1,state:"failed",verification_status:"failed",exit_code:1,evidence_paths:[$exhausted,"exhausted.err"]}]}}
  ]}' > "$selection_primary"
primary_selection="$($ROOT/scripts/select-research-outputs.sh --workers "$selection_primary" --base-dir "$selection_dir")"
[ "$(jq -r '.independent_angle_count' <<<"$primary_selection")" -eq 2 ] || fail 'Bash selector did not retain two independent verified angles'
[ "$(jq '.selected_files | length' <<<"$primary_selection")" -eq 2 ] || fail 'Bash selector did not return two explicit selected files'
[ "$(jq -r '.omitted_workers[0].worker_id' <<<"$primary_selection")" = 'researcher-exhausted' ] || fail 'Bash selector dropped exhausted worker diagnostics'

BASH_SELECTED_FILES=()
while IFS= read -r selected_file; do
  BASH_SELECTED_FILES+=("$selected_file")
done < <(jq -r '.selected_files[]' <<<"$primary_selection" | tr -d '\r')
primary_findings="$($ROOT/scripts/extract-structured-output.sh --array "${BASH_SELECTED_FILES[@]}")"
[ "$(jq 'length' <<<"$primary_findings")" -eq 2 ] || fail 'Bash selector did not provide two findings to extraction'
[ "$(jq -r '.[0].findings[0].claim' <<<"$primary_findings")" = 'official finding' ] || fail 'Bash extraction lost official finding'
[ "$(jq -r '.[1].findings[0].claim' <<<"$primary_findings")" = 'independent finding' ] || fail 'Bash extraction lost independent finding'
pass 'Bash selector feeds only two verified independent angles to extraction'

selection_retry="$selection_dir/retry-routing.json"
jq -n \
  --arg old 'retry-old.json' \
  --arg new 'retry-new.json' \
  '{workers:[{id:"researcher-retry",role:"researcher",status:"completed",output:$new,accepted_attempt:2,routing:{schema_version:1,attempts:[
    {worker_id:"researcher-retry",attempt:1,state:"failed",verification_status:"failed",exit_code:1,evidence_paths:[$old,"retry-old.err"]},
    {worker_id:"researcher-retry",attempt:2,state:"completed",verification_status:"passed",exit_code:0,evidence_paths:[$new,"retry-new.err"]}
  ]}}]}' > "$selection_retry"
retry_selection="$($ROOT/scripts/select-research-outputs.sh --workers "$selection_retry" --base-dir "$selection_dir")"
[ "$(jq -r '.independent_angle_count' <<<"$retry_selection")" -eq 1 ] || fail 'Bash selector counted failed retry as a surviving angle'
[ "$(jq -r '.selected_files[0]' <<<"$retry_selection")" = "$selection_dir/retry-new.json" ] || fail 'Bash selector did not choose the verified retry artifact'
pass 'Bash selector excludes failed attempt and keeps verified retry artifact'

selection_unverified="$selection_dir/unverified-routing.json"
jq -n \
  --arg output 'unverified.json' \
  '{workers:[{id:"researcher-unverified",role:"researcher",status:"completed",output:$output,accepted_attempt:1,routing:{schema_version:1,attempts:[{worker_id:"researcher-unverified",attempt:1,state:"completed",verification_status:"pending",exit_code:0,evidence_paths:[$output,"unverified.err"]}]}}]}' > "$selection_unverified"
unverified_selection="$($ROOT/scripts/select-research-outputs.sh --workers "$selection_unverified" --base-dir "$selection_dir")"
[ "$(jq -r '.independent_angle_count' <<<"$unverified_selection")" -lt 2 ] || fail 'Bash selector did not expose fallback threshold'
[ "$(jq '.selected_files | length' <<<"$unverified_selection")" -eq 0 ] || fail 'Bash selector admitted completed but unverified output'
pass 'Bash selector exposes partial fallback when fewer than two angles survive'

# Citation audit verification tests (Issue #10)
audit_script="$ROOT/scripts/check-citation-audit.sh"

# Help and missing arguments
"$audit_script" --help >/dev/null 2>&1 || fail 'check-citation-audit.sh --help failed'
if "$audit_script" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted empty arguments'
fi
if "$audit_script" --ledger '{not-json' --auditor '{"citation_audits":[]}' >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted malformed ledger JSON'
fi
if "$audit_script" --ledger '[]' --auditor '{not-json' >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted malformed auditor JSON'
fi

std_ledger='[{"claim_id":"c1","claim":"Claim 1","citations":["https://example.com/1","https://example.com/2"],"decision_relevance":"critical","status":"supported"},{"claim_id":"c2","claim":"Claim 2","citations":["https://example.com/3"],"decision_relevance":"supporting","status":"supported"}]'

# Criterion 1: Empty and partial audits rejected even with pass
if "$audit_script" --ledger "$std_ledger" --auditor '{"citation_audits":[],"final_status":"pass"}' >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted empty citation_audits with pass'
fi
if "$audit_script" --ledger "$std_ledger" --auditor '{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}' >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted partial citation_audits missing c2'
fi

# Criterion 2: Duplicate and unknown pairs rejected; two citations for one claim require separate coverage
dup_audits='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
if "$audit_script" --ledger "$std_ledger" --auditor "$dup_audits" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted duplicate audit entry'
fi

unk_audits='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/unknown","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
if "$audit_script" --ledger "$std_ledger" --auditor "$unk_audits" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted unknown audit entry'
fi

single_claim_two_cits='[{"claim_id":"c1","claim":"Claim 1","citations":["https://example.com/a","https://example.com/b"],"decision_relevance":"critical","status":"supported"}]'
single_audit_only='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/a","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
if "$audit_script" --ledger "$single_claim_two_cits" --auditor "$single_audit_only" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted single audit when two citations were required'
fi

# Criterion 3: Supported verdicts only before acceptance; failed or unresolved cannot coexist with pass
resolves_false='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":false,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
if "$audit_script" --ledger "$std_ledger" --auditor "$resolves_false" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted resolves=false with pass'
fi

refutes_audit='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"refutes","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
if "$audit_script" --ledger "$std_ledger" --auditor "$refutes_audit" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted refutes verdict with pass'
fi

partially_audit='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"partially_supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
if "$audit_script" --ledger "$std_ledger" --auditor "$partially_audit" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted partially_supports verdict with pass'
fi

unsupported_audit='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"unsupported","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
if "$audit_script" --ledger "$std_ledger" --auditor "$unsupported_audit" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted unsupported verdict with pass'
fi

remove_with_pass='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass","claims_to_remove":["c1"]}'
if "$audit_script" --ledger "$std_ledger" --auditor "$remove_with_pass" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted claims_to_remove with pass'
fi

narrow_with_pass='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass","claims_to_narrow":["c1"]}'
if "$audit_script" --ledger "$std_ledger" --auditor "$narrow_with_pass" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted claims_to_narrow with pass'
fi

unresolved_with_pass='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass","claims_unresolved":["c1"]}'
if "$audit_script" --ledger "$std_ledger" --auditor "$unresolved_with_pass" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted claims_unresolved with pass'
fi

# Criterion 4: Ledger with no auditable pairs
if "$audit_script" --ledger '[]' --auditor '{"citation_audits":[],"final_status":"pass"}' >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted empty ledger by default without citations'
fi
"$audit_script" --ledger '[]' --auditor '{"citation_audits":[],"final_status":"pass"}' --allow-empty >/dev/null 2>&1 || fail 'check-citation-audit.sh failed on empty ledger with --allow-empty'
if "$audit_script" --ledger '[]' --auditor "$single_audit_only" --allow-empty >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted unexpected audits on empty ledger with --allow-empty'
fi

# Criterion 5: Complete valid coverage and workflow branching
valid_pass='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}'
"$audit_script" --ledger "$std_ledger" --auditor "$valid_pass" >/dev/null 2>&1 || fail 'check-citation-audit.sh failed on complete valid pass'

valid_revise='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"refutes","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"revise","claims_to_remove":["c1"]}'
set +e
"$audit_script" --ledger "$std_ledger" --auditor "$valid_revise" >/dev/null 2>&1
revise_code=$?
set -e
[ "$revise_code" -eq 1 ] || fail "check-citation-audit.sh expected exit code 1 for valid revise, got $revise_code"

contradictory_revise='{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c1","citation_url":"https://example.com/2","resolves":true,"support_verdict":"supports","source_classification":"primary"},{"claim_id":"c2","citation_url":"https://example.com/3","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"revise"}'
if "$audit_script" --ledger "$std_ledger" --auditor "$contradictory_revise" >/dev/null 2>&1; then
  fail 'check-citation-audit.sh accepted contradictory revise without claims to remove/narrow'
fi

# File wrapper input test
wrapper_ledger_file="$TMP_ROOT/synth-wrapper.json"
wrapper_auditor_file="$TMP_ROOT/audit-wrapper.json"
printf '{"structured_output":{"claim_ledger":[{"claim_id":"c1","citations":["https://example.com/1"]}]}}\n' > "$wrapper_ledger_file"
printf '{"structured_output":{"citation_audits":[{"claim_id":"c1","citation_url":"https://example.com/1","resolves":true,"support_verdict":"supports","source_classification":"primary"}],"final_status":"pass"}}\n' > "$wrapper_auditor_file"
"$audit_script" --ledger "$wrapper_ledger_file" --auditor "$wrapper_auditor_file" >/dev/null 2>&1 || fail 'check-citation-audit.sh failed with file wrappers'

# JSON output flag test
json_result="$("$audit_script" --ledger "$wrapper_ledger_file" --auditor "$wrapper_auditor_file" --json)"
[ "$(echo "$json_result" | jq -r '.valid')" = 'true' ] || fail 'check-citation-audit.sh --json valid is not true'
[ "$(echo "$json_result" | jq -r '.status')" = 'pass' ] || fail 'check-citation-audit.sh --json status is not pass'
[ "$(echo "$json_result" | jq -r '.exit_code')" = '0' ] || fail 'check-citation-audit.sh --json exit_code is not 0'
pass 'check-citation-audit validates coverage, duplicate/unknown pairs, verdict consistency, and exit contracts'

# Manual installation instructions in README.md must copy the entire skill directory
if [[ -f "$ROOT/README.md" ]]; then
  ! grep -q 'copy the file' "$ROOT/README.md" || fail "README.md should not say 'copy the file'"
  ! grep -qE 'Copy `?SKILL\.md`?' "$ROOT/README.md" || fail "README.md should not say 'Copy SKILL.md'"
  ! grep -q 'one file' "$ROOT/README.md" || fail "README.md should not claim the skill is one file"
  grep -q 'Asa by Achibukz' "$ROOT/README.md" || fail "README.md missing required Asa attribution"
  # Must instruct copying the skill directory / folder
  grep -qE '(copy|Copy) (the )?(entire |whole )?(skill |offload )?directory|cp -[rR]' "$ROOT/README.md" || fail "README.md must instruct copying the full directory"
fi
pass 'README contains attribution and whole-directory installation guidance'

printf '%s\n' 'all deterministic research-mode acceptance checks passed'
