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
  scripts/extract-structured-output.sh; do
  require_file "$file"
done
pass 'router, modes, and helper files exist'

[ "$(wc -l < "$ROOT/SKILL.md")" -lt 500 ] || fail 'SKILL.md is not below 500 lines'
for mode in execution repo-research web-research; do
  require_text SKILL.md "modes/$mode.md"
done
pass 'router stays short and points to every mode'

if rg -n -i 'plan mode[^.]{0,80}(write barrier|prevents? writes?|cannot write)|--add-dir[^.]{0,80}(confine|sandbox|prevents? writes?)|plan-mode[^.]{0,80}(write barrier|prevents? writes?)' \
  "$ROOT" -g '!tests/test_research_modes.sh' -g '!tests/test_workflow_static.ps1' -g '!.scratch/**'; then
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
  scripts/extract-structured-output.sh; do
  bash -n "$ROOT/$script" || fail "$script does not parse"
  [ -x "$ROOT/$script" ] || fail "$script is not executable"
done
pass 'research helpers parse and are executable'

require_text modes/web-research.md 'run-agy-json.sh'
require_text modes/web-research.md 'extract-structured-output.sh'
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

# Successful cleanup retention (final.md, provenance.json, and marker retained; other children removed)
printf '%s\n' '{"run_id":"run-1","request_summary":"x","selected_mode":"web-research","profile":"standard","deep_trigger":null,"start_time":"2026-01-01T00:00:00Z","end_time":"2026-01-01T00:00:01Z","duration_seconds":1,"scratch_path":"/tmp/run-1","workers":[],"repository_snapshot_paths":[],"final_citations":[],"audit_verdicts":[],"final_status":"success","incomplete_stage_reasons":[]}' > "$workspace/provenance.json"
printf '%s\n' 'final result' > "$workspace/final.md"
printf '%s\n' 'raw result' > "$workspace/raw-worker.json"
mkdir -p "$workspace/repo/nested"
printf '%s\n' 'nested data' > "$workspace/repo/nested/data.txt"
"$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$workspace" --status success
[ -f "$workspace/provenance.json" ] || fail 'successful cleanup removed provenance'
[ -f "$workspace/final.md" ] || fail 'successful cleanup removed final result'
[ -f "$workspace/.offload-research-workspace" ] || fail 'successful cleanup removed workspace marker'
[ "$(cat "$workspace/.offload-research-workspace")" = 'offload-research-workspace-v1' ] || fail 'successful cleanup corrupted workspace marker'
[ ! -e "$workspace/raw-worker.json" ] || fail 'successful cleanup retained raw artifacts'
[ ! -e "$workspace/repo" ] || fail 'successful cleanup retained repo snapshot directory'
pass 'successful cleanup retains final output, provenance, and workspace marker'

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
