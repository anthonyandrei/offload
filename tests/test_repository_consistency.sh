#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
total=0

pass() { total=$((total + 1)); printf 'ok - %s\n' "$1"; }
assert_file() { [[ -f "$1" ]] || { printf 'FAIL: missing file: %s\n' "$1" >&2; exit 1; }; pass "$2"; }
assert_absent() { [[ ! -e "$1" ]] || { printf 'FAIL: path exists: %s\n' "$1" >&2; exit 1; }; pass "$2"; }

active_content=''
for relative in SKILL.md README.md AGENTS.md CONTEXT.md CLAUDE.md .github/workflows/ci.yml docs/adr/0012-keep-offload-outcome-based-and-runtime-dynamic.md docs/adr/0013-use-implicit-invocation-for-the-offer-gate.md docs/research/2026-09-07-benchmark-references-for-runtime-routing.md; do
  assert_file "$root/$relative" "active repository file exists: $relative"
  active_content=$active_content$(cat "$root/$relative")
  active_content=$active_content$'\n'
done

for reference in \
  model-policy.json modes/execution.md modes/repo-research.md modes/web-research.md \
  scripts/dispatch-worker.ps1 scripts/dispatch-worker.sh scripts/run-agy-json.ps1 \
  scripts/run-agy-json.sh scripts/run-claude-json.ps1 scripts/run-claude-json.sh \
  scripts/run-codex-json.ps1 scripts/run-codex-json.sh scripts/select-compatible-worker.ps1 \
  scripts/select-compatible-worker.sh scripts/capacity-ledger.ps1 scripts/resource-ledger.ps1 \
  docs/worker-adapter-contract.md docs/contracts/publication-compatibility.md; do
  if [[ "$active_content" == *"$reference"* ]]; then
    printf 'FAIL: active docs mention removed reference: %s\n' "$reference" >&2
    exit 1
  fi
  pass "active docs omit removed reference: $reference"
done

for relative in \
  SKILL.md README.md CONTEXT.md AGENTS.md CLAUDE.md \
  scripts/check-execution-scope.ps1 scripts/check-execution-scope.sh \
  scripts/execution-workspace.ps1 scripts/execution-workspace.sh \
  scripts/make-research-workspace.ps1 scripts/make-research-workspace.sh \
  scripts/cleanup-research-workspace.ps1 scripts/cleanup-research-workspace.sh; do
  assert_file "$root/$relative" "skill package includes $relative"
done

for relative in \
  scripts/agy-adapter.ps1 scripts/capacity-ledger.ps1 scripts/check-worker-adapter.ps1 \
  scripts/dispatch-worker.ps1 scripts/run-agy-json.ps1 scripts/select-compatible-worker.ps1 \
  docs/specs/0001-platform-agnostic-workflows.md docs/worker-adapter-contract.md; do
  assert_absent "$root/$relative" "removed package path is absent: $relative"
done

skill=$(<"$root/SKILL.md")
readme=$(<"$root/README.md")
for link in CONTEXT.md docs/adr/0012-keep-offload-outcome-based-and-runtime-dynamic.md docs/adr/0013-use-implicit-invocation-for-the-offer-gate.md docs/research/2026-09-07-benchmark-references-for-runtime-routing.md scripts/check-execution-scope.sh scripts/execution-workspace.sh; do
  [[ "$skill" == *"$link"* || "$readme" == *"$link"* ]] || { printf 'FAIL: active docs lack link: %s\n' "$link" >&2; exit 1; }
  pass "active docs retain link: $link"
done

for doc in SKILL.md README.md AGENTS.md CONTEXT.md CLAUDE.md; do
  doc_content=$(<"$root/$doc")
  for adr in \
    0001-maintain-shell-native-helper-families.md \
    0003-use-a-portable-proactive-offer-contract.md \
    0005-bound-model-routing-to-gemini-and-explicit-rules.md \
    0007-cross-library-publication-boundaries.md \
    0008-runtime-model-selection-through-adapters.md \
    0009-select-compatible-workers-before-offering-offload.md \
    0010-agy-preflight-discovery.md \
    0011-launch-first-admission-and-orchestrator-fallback.md; do
    [[ "$doc_content" != *"$adr"* ]] || { printf 'FAIL: %s links to superseded ADR: %s\n' "$doc" "$adr" >&2; exit 1; }
    pass "$doc omits link to superseded ADR: $adr"
  done
done

printf 'all bash repository consistency checks passed (%s tests)\n' "$total"
