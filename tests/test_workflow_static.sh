#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
total=0

pass() {
  total=$((total + 1))
  printf 'ok - %s\n' "$1"
}

assert_file() {
  [[ -f "$1" ]] || { printf 'FAIL: missing file: %s\n' "$1" >&2; exit 1; }
  pass "file exists: ${1#$root/}"
}

assert_contains() {
  local content=$1 needle=$2 name=$3
  printf '%s' "$content" | grep -Fqi -- "$needle" || { printf 'FAIL: %s\n' "$name" >&2; exit 1; }
  pass "$name"
}

assert_absent() {
  [[ ! -e "$1" ]] || { printf 'FAIL: path exists: %s\n' "$1" >&2; exit 1; }
  pass "removed path is absent: ${1#$root/}"
}

skill=$(<"$root/SKILL.md")
readme=$(<"$root/README.md")
agents=$(<"$root/AGENTS.md")
context=$(<"$root/CONTEXT.md")
ci=$(<"$root/.github/workflows/ci.yml")

for path in "$root/SKILL.md" "$root/README.md" "$root/AGENTS.md" "$root/CONTEXT.md"; do
  assert_file "$path"
done

for phrase in bounded runtime 'native help' 'acceptance criteria' launch unfinished orchestrator disposable citation inference nested; do
  assert_contains "$skill" "$phrase" "SKILL.md states $phrase"
done
for phrase in runtime benchmark launch unfinished isolated citation inference provider; do
  assert_contains "$readme" "$phrase" "README.md states $phrase"
done
for content in "$skill" "$readme"; do
  [[ "$content" != *'```'* ]] || { printf 'FAIL: active contract has copied command blocks\n' >&2; exit 1; }
  pass 'active contract has no copied command blocks'
done

for content_name in skill readme agents context; do
  content=${!content_name}
  for term in model-policy.json 'modes/' 'modes\\' dispatch-worker run-agy-json run-claude-json run-codex-json select-compatible-worker capacity-ledger resource-ledger routing-outcomes worker-adapter publication-compatibility schema_version; do
    [[ "$content" != *"$term"* ]] || { printf 'FAIL: %s contains %s\n' "$content_name" "$term" >&2; exit 1; }
    pass "$content_name omits $term"
  done
  if [[ "$content_name" != context ]]; then
    if printf '%s\n' "$content" | grep -Eiq '(^|[^[:alpha:]])(agy|claude|codex|gemini)([^[:alpha:]]|$)'; then
      printf 'FAIL: %s contains a copied vendor name\n' "$content_name" >&2
      exit 1
    fi
    pass "$content_name omits copied vendor names"
  fi
done

for relative in \
  model-policy.json modes/execution.md modes/repo-research.md modes/web-research.md \
  scripts/dispatch-worker.sh scripts/run-agy-json.sh scripts/run-claude-json.sh \
  scripts/run-codex-json.sh scripts/select-compatible-worker.sh \
  scripts/capacity-ledger.sh scripts/resource-ledger.sh docs/specs/0001-platform-agnostic-workflows.md; do
  assert_absent "$root/$relative"
done

for relative in \
  scripts/check-execution-scope.ps1 scripts/check-execution-scope.sh \
  scripts/execution-workspace.ps1 scripts/execution-workspace.sh \
  scripts/make-research-workspace.ps1 scripts/make-research-workspace.sh \
  scripts/cleanup-research-workspace.ps1 scripts/cleanup-research-workspace.sh \
  tests/test_execution_scope.ps1 tests/test_execution_scope.sh \
  tests/test_execution_workspace.ps1 tests/test_execution_workspace.sh \
  tests/test_research_workspace.ps1 tests/test_research_workspace.sh \
  tests/test_research_acceptance.ps1 tests/test_research_acceptance.sh \
  tests/test_worker_failure.ps1 tests/test_worker_failure.sh \
  tests/test_repository_consistency.ps1 tests/test_repository_consistency.sh; do
  assert_file "$root/$relative"
done

for old_test in test_model_routing test_agy_preflight test_worker_adapter_contract test_research_modes test_resource_ledger; do
  [[ "$ci" != *"$old_test"* ]] || { printf 'FAIL: CI still runs %s\n' "$old_test" >&2; exit 1; }
  pass "CI omits removed test: $old_test"
done
for test_name in test_workflow_static test_execution_scope test_execution_workspace test_research_workspace test_research_acceptance test_worker_failure test_repository_consistency; do
  assert_contains "$ci" "$test_name" "CI runs current test: $test_name"
done

printf 'all workflow static checks passed (%s tests)\n' "$total"
