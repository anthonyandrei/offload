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
  "$ROOT" -g '!tests/test_research_modes.sh' -g '!.scratch/**'; then
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
  scripts/cleanup-research-workspace.sh; do
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

printf '%s\n' '{"run_id":"run-1","request_summary":"x","selected_mode":"web-research","profile":"standard","deep_trigger":null,"start_time":"2026-01-01T00:00:00Z","end_time":"2026-01-01T00:00:01Z","duration_seconds":1,"scratch_path":"/tmp/run-1","workers":[],"repository_snapshot_paths":[],"final_citations":[],"audit_verdicts":[],"final_status":"success","incomplete_stage_reasons":[]}' > "$workspace/provenance.json"
printf '%s\n' 'final result' > "$workspace/final.md"
printf '%s\n' 'raw result' > "$workspace/raw-worker.json"
"$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$workspace" --status success
[ -f "$workspace/provenance.json" ] || fail 'successful cleanup removed provenance'
[ -f "$workspace/final.md" ] || fail 'successful cleanup removed final result'
[ ! -e "$workspace/raw-worker.json" ] || fail 'successful cleanup retained raw artifacts'
pass 'successful cleanup retains final output and provenance'

workspace_failed=$(
  "$ROOT/scripts/make-research-workspace.sh" \
    --source-repo "$fixture" \
    --path declared/keep.txt
)
printf '%s\n' 'raw result' > "$workspace_failed/raw-worker.json"
"$ROOT/scripts/cleanup-research-workspace.sh" --workspace "$workspace_failed" --status partial
[ -f "$workspace_failed/raw-worker.json" ] || fail 'failed cleanup removed raw artifacts'
pass 'partial cleanup retains raw artifacts'

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
