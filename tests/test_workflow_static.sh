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

assert_ordered() {
  local content=$1 first=$2 second=$3 third=$4 name=$5
  content=$(printf '%s' "$content" | tr '[:upper:]' '[:lower:]')
  local after_first=${content#*"$first"}
  [[ "$after_first" != "$content" ]] || { printf 'FAIL: %s\n' "$name" >&2; exit 1; }
  local after_second=${after_first#*"$second"}
  [[ "$after_second" != "$after_first" ]] || { printf 'FAIL: %s\n' "$name" >&2; exit 1; }
  [[ "$after_second" == *"$third"* ]] || { printf 'FAIL: %s\n' "$name" >&2; exit 1; }
  pass "$name"
}

skill=$(<"$root/SKILL.md")
readme=$(<"$root/README.md")
ci=$(<"$root/.github/workflows/ci.yml")

for path in "$root/SKILL.md" "$root/README.md"; do
  assert_file "$path"
done

for work_class in \
  'repository reconnaissance' 'analysis' 'test investigation' 'implementation' \
  'research' 'transformations' 'artifact-producing work' \
  'independently executable long-running work'; do
  assert_contains "$skill" "$work_class" "SKILL.md names bounded work class: $work_class"
  assert_contains "$readme" "$work_class" "README.md names bounded work class: $work_class"
done
for phrase in bounded runtime 'acceptance criteria' launch unfinished orchestrator disposable citation inference nested 'external vendor' quality price escalation benchmark usage; do
  assert_contains "$skill" "$phrase" "SKILL.md states $phrase"
done
for phrase in runtime benchmark launch unfinished isolated citation inference 'external vendor' quality price escalation usage; do
  assert_contains "$readme" "$phrase" "README.md states $phrase"
done
for phrase in \
  'best matches the task' 'exact model and reasoning effort' 'most accurate candidate' \
  'same benchmark context' 'price is a clear outlier' 'material quality advantage' \
  'not a fixed multiplier' 'current runtime or published pricing' \
  'benchmark cost is comparative evidence' 'If several benchmarks apply' \
  'Do not combine incomparable benchmarks or scores into a synthetic ranking'; do
  assert_contains "$skill" "$phrase" "SKILL.md states routing rule: $phrase"
done
assert_contains "$readme" 'most accurate capable model and effort' 'README.md states quality-first routing'
assert_contains "$readme" 'clear price outlier' 'README.md states relative price guardrail'
[[ "$skill" != *'lightest model'* ]] || { printf 'FAIL: SKILL.md retains superseded lightest-model preference\n' >&2; exit 1; }
pass 'SKILL.md omits superseded lightest-model preference'
[[ "$readme" != *'lightest capable model'* ]] || { printf 'FAIL: README.md retains superseded lightest-model preference\n' >&2; exit 1; }
pass 'README.md omits superseded lightest-model preference'
assert_contains "$skill" 'Open-ended, indefinite, or tightly interactive work stays local.' 'SKILL.md keeps open-ended and tightly interactive work local'
assert_contains "$readme" 'Open-ended or tightly interactive work stays local.' 'README.md keeps open-ended and tightly interactive work local'
assert_contains "$skill" 'Every assignment uses the same shape: objective, scope, acceptance criteria, deliverables, and authority.' 'SKILL.md defines the generic assignment shape'
assert_contains "$readme" 'objective, scope, acceptance criteria, deliverables, and authority' 'README.md repeats the generic assignment shape'
assert_contains "$skill" 'shared authority and acceptance criteria' 'SKILL.md permits shared-authority phases'
assert_contains "$skill" 'Genuinely independent work keeps separate boundaries' 'SKILL.md separates independent work'
assert_ordered "$skill" 'version-matched official documentation' 'installed version and native help' 'real launch is the definitive admission check' 'SKILL.md states runtime discovery precedence'
assert_contains "$skill" 'transient launch record' 'SKILL.md keeps launch facts transient'
for launch_fact in 'selected tool' 'installed version' 'documentation source' 'invocation shape' 'model or effort setting' 'usage observation' 'launch result'; do
  assert_contains "$skill" "$launch_fact" "SKILL.md reports launch fact: $launch_fact"
done
for secret_term in credentials tokens secrets; do
  assert_contains "$skill" "$secret_term" "SKILL.md excludes $secret_term from run records"
done
assert_contains "$skill" 'confirmed exhaustion removes a candidate' 'SKILL.md handles confirmed exhaustion'
assert_contains "$skill" 'unknown or stale evidence does not block launch' 'SKILL.md treats unknown evidence as non-blocking'
assert_contains "$skill" 'named vendor' 'SKILL.md honors named vendors'
assert_contains "$skill" 'exact model' 'SKILL.md honors exact models'
assert_contains "$skill" 'infrastructure failures' 'SKILL.md identifies infrastructure failures'
assert_contains "$skill" 'exactly one automatic escalation' 'SKILL.md limits quality escalation'
assert_contains "$skill" 'cleanup status' 'SKILL.md requires cleanup status in the final report'
assert_contains "$skill" 'every terminal path' 'SKILL.md requires cleanup on every terminal path'
assert_contains "$skill" 'exact path' 'SKILL.md reports the cleanup path on failure'

expected_description="description: Outsource bounded repository reconnaissance, analysis, test investigation, implementation, research, transformations, artifact-producing work, and independently executable long-running work to an external vendor. Use when the user explicitly asks to offload, names an external vendor or model, approves outsourcing after the orchestrator defines a bounded assignment, or a bounded task would otherwise be delegated to a native subagent and needs an external alternative."
assert_contains "$skill" "$expected_description" "SKILL.md uses exact settled frontmatter description"

frontmatter=$(sed -n '2,/^---$/p' "$root/SKILL.md")
[[ "$frontmatter" != *"Do NOT"* ]] || { printf 'FAIL: SKILL.md frontmatter contains Do NOT\n' >&2; exit 1; }
pass "SKILL.md frontmatter omits negative Do NOT sentence"

for stale_phrase in "native multi-agent workflow" "two or more" "delegation lanes" "proactive offer gate" "two-lane" "host instructions" "host-approved" "three independently gated" "at least three" "silent provider switch" "second automatic attempt"; do
  [[ "$skill" != *"$stale_phrase"* ]] || { printf 'FAIL: SKILL.md contains stale phrase: %s\n' "$stale_phrase" >&2; exit 1; }
  pass "SKILL.md omits stale offer phrase: $stale_phrase"
  [[ "$readme" != *"$stale_phrase"* ]] || { printf 'FAIL: README.md contains stale phrase: %s\n' "$stale_phrase" >&2; exit 1; }
  pass "README.md omits stale offer phrase: $stale_phrase"
done
for content in "$skill" "$readme"; do
  [[ "$content" != *'```'* ]] || { printf 'FAIL: active contract has copied command blocks\n' >&2; exit 1; }
  pass 'active contract has no copied command blocks'
done

for content_name in skill readme; do
  content=${!content_name}
  for term in model-policy.json 'modes/' 'modes\\' dispatch-worker run-agy-json run-claude-json run-codex-json select-compatible-worker capacity-ledger resource-ledger routing-outcomes worker-adapter publication-compatibility schema_version 'vendor catalog' 'command table' 'model matrix' 'provider interface' 'persistent usage telemetry' 'performance ledger' 'quota protocol' 'role matrix' 'routing algorithm'; do
    [[ "$content" != *"$term"* ]] || { printf 'FAIL: %s contains %s\n' "$content_name" "$term" >&2; exit 1; }
    pass "$content_name omits $term"
  done
  if printf '%s\n' "$content" | grep -Eiq '(^|[^[:alpha:]])(agy|claude|codex|gemini)([^[:alpha:]]|$)'; then
    printf 'FAIL: %s contains a copied vendor name\n' "$content_name" >&2
    exit 1
  fi
  pass "$content_name omits copied vendor names"
done

for source in \
  'https://deepswe.datacurve.ai/' 'https://livebench.ai/' \
  'https://drb.futuresearch.ai/' 'https://deepresearch-bench.github.io/' \
  'https://artificialanalysis.ai/models'; do
  assert_contains "$skill" "$source" "SKILL.md retains benchmark source: $source"
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
