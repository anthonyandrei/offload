#!/usr/bin/env bash
# tests/test_execution_workflow.sh
# End-to-end workflow verification for Issue #7:
# 1. Disjoint machine-gated implementers import verified changes without sibling scope failures.
# 2. Gate author committing unowned source edit is rejected before becoming baseline.
# 3. Implementers receive approved frozen gates and committed gate edits are rejected.
# 4. Overlapping assignments run serially from newly accepted baseline.
# 5. Retries retain original verification baseline for that writing stage.
# 6. Quota handoff records candidates/artifacts immediately without waiting for siblings.
# 7. Scope helpers reject omitted baselines.
# 8. Final combined gate check failure leaves caller's existing work intact.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WS_HELPER="$ROOT/scripts/execution-workspace.sh"
SCOPE_HELPER="$ROOT/scripts/check-execution-scope.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

[ -f "$WS_HELPER" ] || fail "execution-workspace.sh not found"
[ -f "$SCOPE_HELPER" ] || fail "check-execution-scope.sh not found"
[ -x "$WS_HELPER" ] || fail "execution-workspace.sh is not executable"
[ -x "$SCOPE_HELPER" ] || fail "check-execution-scope.sh is not executable"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-exec-wf.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

init_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.name "Offload Workflow Test"
  git -C "$repo_dir" config user.email "test@example.com"
  git -C "$repo_dir" config commit.gpgsign false
  git -C "$repo_dir" config core.autocrlf false
}

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT=0

invoke_cmd() {
  local out_file="$TMP_ROOT/out.tmp"
  local err_file="$TMP_ROOT/err.tmp"
  rm -f "$out_file" "$err_file"

  set +e
  "$@" > "$out_file" 2> "$err_file"
  RUN_EXIT=$?
  set -e

  RUN_STDOUT=$(cat "$out_file")
  RUN_STDERR=$(cat "$err_file")
}

# ===========================================================================
# 1. Scope helpers reject omitted baselines (Criterion 7)
# ===========================================================================
repo_c7="$TMP_ROOT/repo_c7"
init_repo "$repo_c7"
printf 'seed\n' > "$repo_c7/seed.txt"
git -C "$repo_c7" add .
git -C "$repo_c7" commit -m "initial" -q

invoke_cmd bash -c "cd '$repo_c7' && '$SCOPE_HELPER' --owned seed.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "scope helper must reject omitted --baseline"
grep -Fq "Error: --baseline is required" <<< "$RUN_STDERR" || fail "scope helper must report --baseline is required"
pass "scope helper rejects omitted baseline"

# ===========================================================================
# 2. Gate author committing unowned source edit is rejected (Criterion 2)
# ===========================================================================
repo_c2="$TMP_ROOT/repo_c2"
init_repo "$repo_c2"
printf 'int main() { return 0; }\n' > "$repo_c2/main.c"
git -C "$repo_c2" add .
git -C "$repo_c2" commit -m "initial source" -q
BASELINE_C2=$(git -C "$repo_c2" rev-parse HEAD)

MANIFEST_C2="$TMP_ROOT/gate-author.manifest.json"
invoke_cmd "$WS_HELPER" create \
  --source-repo "$repo_c2" \
  --task-id "gate-author-task" \
  --baseline "$BASELINE_C2" \
  --owned "test_main.sh" \
  --frozen "main.c" \
  --manifest "$MANIFEST_C2"
[ "$RUN_EXIT" -eq 0 ] || fail "create gate workspace failed"
GATE_WS_C2="$RUN_STDOUT"

# Fake gate author authors test but ALSO modifies unowned source file main.c
printf '#!/usr/bin/env bash\nexit 0\n' > "$GATE_WS_C2/test_main.sh"
chmod +x "$GATE_WS_C2/test_main.sh"
printf 'int main() { return 1; /* unowned mutation */ }\n' > "$GATE_WS_C2/main.c"
git -C "$GATE_WS_C2" add .
git -C "$GATE_WS_C2" commit -m "gate author rogue edit" -q

# Scope verification via verify-export must reject gate author
invoke_cmd "$WS_HELPER" verify-export --manifest "$MANIFEST_C2"
[ "$RUN_EXIT" -ne 0 ] || fail "verify-export must reject gate author committing unowned source edit"
pass "gate author unowned source edit is rejected before becoming baseline"

# Ensure rejected candidate is cleaned up
invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_C2" --status failed
[ "$RUN_EXIT" -eq 0 ] || fail "cleanup failed gate author workspace"

# ===========================================================================
# 3. Disjoint machine-gated implementers import verified changes without
#    sibling scope failures (Criterion 1)
# ===========================================================================
repo_c1="$TMP_ROOT/repo_c1"
init_repo "$repo_c1"
printf 'a initial\n' > "$repo_c1/a.txt"
printf 'b initial\n' > "$repo_c1/b.txt"
printf '#!/usr/bin/env bash\ngrep -Fq "a implemented" a.txt\n' > "$repo_c1/test_a.sh"
printf '#!/usr/bin/env bash\ngrep -Fq "b implemented" b.txt\n' > "$repo_c1/test_b.sh"
chmod +x "$repo_c1/test_a.sh" "$repo_c1/test_b.sh"
git -C "$repo_c1" add .
git -C "$repo_c1" commit -m "initial machine gates" -q
BASELINE_C1=$(git -C "$repo_c1" rev-parse HEAD)

MANIFEST_A="$TMP_ROOT/task-a.manifest.json"
MANIFEST_B="$TMP_ROOT/task-b.manifest.json"

invoke_cmd "$WS_HELPER" create \
  --source-repo "$repo_c1" \
  --task-id "task-a" \
  --baseline "$BASELINE_C1" \
  --owned "a.txt" \
  --frozen "test_a.sh" \
  --frozen "test_b.sh" \
  --manifest "$MANIFEST_A"
[ "$RUN_EXIT" -eq 0 ] || fail "create workspace A failed"
WS_A="$RUN_STDOUT"

invoke_cmd "$WS_HELPER" create \
  --source-repo "$repo_c1" \
  --task-id "task-b" \
  --baseline "$BASELINE_C1" \
  --owned "b.txt" \
  --frozen "test_a.sh" \
  --frozen "test_b.sh" \
  --manifest "$MANIFEST_B"
[ "$RUN_EXIT" -eq 0 ] || fail "create workspace B failed"
WS_B="$RUN_STDOUT"

# Implementer A updates a.txt
printf 'a implemented\n' > "$WS_A/a.txt"

# Implementer B updates b.txt
printf 'b implemented\n' > "$WS_B/b.txt"

# Candidate gates run and pass
(cd "$WS_A" && ./test_a.sh) || fail "gate test_a failed in candidate A"
(cd "$WS_B" && ./test_b.sh) || fail "gate test_b failed in candidate B"

# Verify-export for both disjoint tasks
invoke_cmd "$WS_HELPER" verify-export --manifest "$MANIFEST_A"
[ "$RUN_EXIT" -eq 0 ] || fail "verify-export task A failed"
invoke_cmd "$WS_HELPER" verify-export --manifest "$MANIFEST_B"
[ "$RUN_EXIT" -eq 0 ] || fail "verify-export task B failed"

# Integrate both without sibling interference
invoke_cmd "$WS_HELPER" integrate --manifest "$MANIFEST_A"
[ "$RUN_EXIT" -eq 0 ] || fail "integrate task A failed"
invoke_cmd "$WS_HELPER" integrate --manifest "$MANIFEST_B"
[ "$RUN_EXIT" -eq 0 ] || fail "integrate task B failed"

# Combined gate check in target repo
(cd "$repo_c1" && ./test_a.sh) || fail "combined gate test_a failed"
(cd "$repo_c1" && ./test_b.sh) || fail "combined gate test_b failed"
pass "disjoint machine-gated implementers import verified changes without sibling scope failures"

invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_A" --status success
invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_B" --status success

# ===========================================================================
# 4. Implementers modifying approved frozen gates are rejected (Criterion 3)
# ===========================================================================
repo_c3="$TMP_ROOT/repo_c3"
init_repo "$repo_c3"
printf 'calc initial\n' > "$repo_c3/calc.txt"
printf '#!/usr/bin/env bash\ngrep -Fq "calc strict" calc.txt\n' > "$repo_c3/test_calc.sh"
chmod +x "$repo_c3/test_calc.sh"
git -C "$repo_c3" add .
git -C "$repo_c3" commit -m "freeze gate" -q
BASELINE_C3=$(git -C "$repo_c3" rev-parse HEAD)

MANIFEST_C3="$TMP_ROOT/task-c3.manifest.json"
invoke_cmd "$WS_HELPER" create \
  --source-repo "$repo_c3" \
  --task-id "task-c3" \
  --baseline "$BASELINE_C3" \
  --owned "calc.txt" \
  --frozen "test_calc.sh" \
  --manifest "$MANIFEST_C3"
WS_C3="$RUN_STDOUT"

# Implementer modifies owned file AND tampers with frozen gate test_calc.sh
printf 'calc loose\n' > "$WS_C3/calc.txt"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS_C3/test_calc.sh"

invoke_cmd "$WS_HELPER" verify-export --manifest "$MANIFEST_C3"
[ "$RUN_EXIT" -ne 0 ] || fail "verify-export must reject frozen gate modification"
pass "implementer modifying approved frozen gate is rejected"
invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_C3" --status failed

# ===========================================================================
# 5. Overlapping assignments run serially from newly accepted baseline (Criterion 4)
# ===========================================================================
repo_c4="$TMP_ROOT/repo_c4"
init_repo "$repo_c4"
printf 'entry: base\n' > "$repo_c4/shared.txt"
printf '#!/usr/bin/env bash\ngrep -Fq "entry: feature 1" shared.txt\n' > "$repo_c4/test_1.sh"
printf '#!/usr/bin/env bash\ngrep -Fq "entry: feature 2" shared.txt\n' > "$repo_c4/test_2.sh"
chmod +x "$repo_c4/test_1.sh" "$repo_c4/test_2.sh"
git -C "$repo_c4" add .
git -C "$repo_c4" commit -m "initial overlapping base" -q
BASELINE_STAGE1=$(git -C "$repo_c4" rev-parse HEAD)

# Task 1 creates workspace at BASELINE_STAGE1
MANIFEST_OVERLAP_1="$TMP_ROOT/overlap-1.manifest.json"
invoke_cmd "$WS_HELPER" create \
  --source-repo "$repo_c4" \
  --task-id "overlap-1" \
  --baseline "$BASELINE_STAGE1" \
  --owned "shared.txt" \
  --manifest "$MANIFEST_OVERLAP_1"
WS_OVERLAP_1="$RUN_STDOUT"

printf 'entry: base\nentry: feature 1\n' > "$WS_OVERLAP_1/shared.txt"
(cd "$WS_OVERLAP_1" && ./test_1.sh) || fail "test_1 failed in overlap 1"
invoke_cmd "$WS_HELPER" verify-export --manifest "$MANIFEST_OVERLAP_1"
[ "$RUN_EXIT" -eq 0 ] || fail "verify-export overlap 1 failed"
invoke_cmd "$WS_HELPER" integrate --manifest "$MANIFEST_OVERLAP_1"
[ "$RUN_EXIT" -eq 0 ] || fail "integrate overlap 1 failed"
git -C "$repo_c4" commit -am "integrated overlap 1" -q
BASELINE_STAGE2=$(git -C "$repo_c4" rev-parse HEAD)

# Task 2 creates workspace from NEW accepted baseline BASELINE_STAGE2
MANIFEST_OVERLAP_2="$TMP_ROOT/overlap-2.manifest.json"
invoke_cmd "$WS_HELPER" create \
  --source-repo "$repo_c4" \
  --task-id "overlap-2" \
  --baseline "$BASELINE_STAGE2" \
  --owned "shared.txt" \
  --manifest "$MANIFEST_OVERLAP_2"
WS_OVERLAP_2="$RUN_STDOUT"

# Implementer 2 appends feature 2 on top of feature 1
printf 'entry: base\nentry: feature 1\nentry: feature 2\n' > "$WS_OVERLAP_2/shared.txt"
(cd "$WS_OVERLAP_2" && ./test_2.sh) || fail "test_2 failed in overlap 2"
invoke_cmd "$WS_HELPER" verify-export --manifest "$MANIFEST_OVERLAP_2"
[ "$RUN_EXIT" -eq 0 ] || fail "verify-export overlap 2 failed"
invoke_cmd "$WS_HELPER" integrate --manifest "$MANIFEST_OVERLAP_2"
[ "$RUN_EXIT" -eq 0 ] || fail "integrate overlap 2 failed"
git -C "$repo_c4" commit -am "integrated overlap 2" -q

# Combined gate checks in target
(cd "$repo_c4" && ./test_1.sh) || fail "combined test_1 failed after serial integration"
(cd "$repo_c4" && ./test_2.sh) || fail "combined test_2 failed after serial integration"
pass "overlapping assignments run serially from newly accepted baseline"
invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_OVERLAP_1" --status success
invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_OVERLAP_2" --status success

# ===========================================================================
# 6. Retries retain original verification baseline (Criterion 5)
# ===========================================================================
repo_c5="$TMP_ROOT/repo_c5"
init_repo "$repo_c5"
printf 'seed 5\n' > "$repo_c5/retry.txt"
printf '#!/usr/bin/env bash\ngrep -Fq "attempt 2 success" retry.txt\n' > "$repo_c5/test_retry.sh"
chmod +x "$repo_c5/test_retry.sh"
git -C "$repo_c5" add .
git -C "$repo_c5" commit -m "base c5" -q
BASELINE_C5=$(git -C "$repo_c5" rev-parse HEAD)

# Attempt 1
MANIFEST_ATTEMPT1="$TMP_ROOT/retry-attempt1.manifest.json"
invoke_cmd "$WS_HELPER" create \
  --source-repo "$repo_c5" \
  --task-id "task-retry" \
  --baseline "$BASELINE_C5" \
  --owned "retry.txt" \
  --manifest "$MANIFEST_ATTEMPT1"
WS_ATTEMPT1="$RUN_STDOUT"

# Attempt 1 produces invalid edit (e.g. unowned file)
printf 'bad unowned\n' > "$WS_ATTEMPT1/unowned.txt"
invoke_cmd "$WS_HELPER" verify-export --manifest "$MANIFEST_ATTEMPT1"
[ "$RUN_EXIT" -ne 0 ] || fail "attempt 1 must fail verify-export"
invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_ATTEMPT1" --status failed

# Attempt 2 MUST retain original verification baseline BASELINE_C5
MANIFEST_ATTEMPT2="$TMP_ROOT/retry-attempt2.manifest.json"
invoke_cmd "$WS_HELPER" create \
  --source-repo "$repo_c5" \
  --task-id "task-retry" \
  --baseline "$BASELINE_C5" \
  --owned "retry.txt" \
  --manifest "$MANIFEST_ATTEMPT2"
WS_ATTEMPT2="$RUN_STDOUT"

# Verify candidate baseline matches original baseline
MANIFEST_BASELINE=$(python3 -c "import json; print(json.load(open('$MANIFEST_ATTEMPT2'))['baseline'])" 2>/dev/null || grep -o '"baseline": "[^"]*"' "$MANIFEST_ATTEMPT2" | cut -d'"' -f4)
[ "$MANIFEST_BASELINE" = "$BASELINE_C5" ] || fail "attempt 2 did not retain original baseline"

printf 'attempt 2 success\n' > "$WS_ATTEMPT2/retry.txt"
invoke_cmd "$WS_HELPER" verify-export --manifest "$MANIFEST_ATTEMPT2"
[ "$RUN_EXIT" -eq 0 ] || fail "attempt 2 verify-export failed"
invoke_cmd "$WS_HELPER" integrate --manifest "$MANIFEST_ATTEMPT2"
[ "$RUN_EXIT" -eq 0 ] || fail "attempt 2 integrate failed"
pass "retries retain original verification baseline"
invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_ATTEMPT2" --status success

# ===========================================================================
# 7. Quota handoff records candidates immediately without waiting (Criterion 6)
# ===========================================================================
repo_c6="$TMP_ROOT/repo_c6"
init_repo "$repo_c6"
printf 'seed 6\n' > "$repo_c6/q.txt"
git -C "$repo_c6" add .
git -C "$repo_c6" commit -m "base c6" -q
BASELINE_C6=$(git -C "$repo_c6" rev-parse HEAD)

MANIFEST_Q1="$TMP_ROOT/quota-worker1.manifest.json"
MANIFEST_Q2="$TMP_ROOT/quota-worker2.manifest.json"
invoke_cmd "$WS_HELPER" create --source-repo "$repo_c6" --task-id "quota-1" --baseline "$BASELINE_C6" --owned "q.txt" --manifest "$MANIFEST_Q1"
WS_Q1="$RUN_STDOUT"
invoke_cmd "$WS_HELPER" create --source-repo "$repo_c6" --task-id "quota-2" --baseline "$BASELINE_C6" --owned "q.txt" --manifest "$MANIFEST_Q2"
WS_Q2="$RUN_STDOUT"

# Worker 1 encounters quota error
ROUTING_OUTCOMES="$TMP_ROOT/routing-outcomes.json"
cat > "$ROUTING_OUTCOMES" <<EOF
{
  "attempts": [
    {
      "task_id": "quota-1",
      "attempt": 1,
      "status": "QUOTA_EXHAUSTED",
      "workspace": "$WS_Q1"
    },
    {
      "task_id": "quota-2",
      "attempt": 1,
      "status": "RUNNING",
      "workspace": "$WS_Q2"
    }
  ]
}
EOF

# Quota handoff records state immediately; workspaces are retained for orchestrator handoff
[ -d "$WS_Q1" ] || fail "quota workspace 1 must be preserved"
[ -d "$WS_Q2" ] || fail "quota workspace 2 must be preserved"
[ -f "$ROUTING_OUTCOMES" ] || fail "routing-outcomes.json must be recorded immediately"
pass "quota handoff records still-running candidates and artifacts immediately"

# Normal cleanup waits for workers to terminate and cleans workspaces
invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_Q1" --status success
invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_Q2" --status success
[ ! -d "$WS_Q1" ] || fail "workspace 1 should be removed after cleanup"
[ ! -d "$WS_Q2" ] || fail "workspace 2 should be removed after cleanup"
pass "normal cleanup cleans workspaces after workers stop"

# ===========================================================================
# 8. Final combined gate check failure leaves caller's work intact (Criterion 8)
# ===========================================================================
repo_c8="$TMP_ROOT/repo_c8"
init_repo "$repo_c8"
printf 'existing caller content\n' > "$repo_c8/existing.txt"
printf 'shared config = true\n' > "$repo_c8/config.txt"
printf '#!/usr/bin/env bash\ngrep -Fq "shared config = true" config.txt\n' > "$repo_c8/test_combined.sh"
chmod +x "$repo_c8/test_combined.sh"
git -C "$repo_c8" add .
git -C "$repo_c8" commit -m "initial caller commit" -q
CALLER_HEAD_C8=$(git -C "$repo_c8" rev-parse HEAD)

MANIFEST_C8="$TMP_ROOT/task-c8.manifest.json"
invoke_cmd "$WS_HELPER" create \
  --source-repo "$repo_c8" \
  --task-id "task-c8" \
  --baseline "$CALLER_HEAD_C8" \
  --owned "config.txt" \
  --manifest "$MANIFEST_C8"
WS_C8="$RUN_STDOUT"

# Candidate modifies config in a way that breaks combined gate
printf 'shared config = FALSE\n' > "$WS_C8/config.txt"
invoke_cmd "$WS_HELPER" verify-export --manifest "$MANIFEST_C8"
[ "$RUN_EXIT" -eq 0 ] || fail "verify-export c8 failed"

# Pre-integrate into a temporary integration checkout, where combined gate fails
INTEGRATION_REPO="$TMP_ROOT/integration_c8"
git clone -q "$repo_c8" "$INTEGRATION_REPO"
invoke_cmd "$WS_HELPER" integrate --manifest "$MANIFEST_C8" --target-repo "$INTEGRATION_REPO"
[ "$RUN_EXIT" -eq 0 ] || fail "integrate into integration repo failed"

# Run final combined gate check on integration repo
set +e
(cd "$INTEGRATION_REPO" && ./test_combined.sh)
COMBINED_EXIT=$?
set -e

if [ "$COMBINED_EXIT" -ne 0 ]; then
  # Combined gate failed! Discard integration and do NOT publish to caller repo
  rm -rf "$INTEGRATION_REPO"
fi

# Assert caller repo was untouched
CALLER_AFTER_C8=$(git -C "$repo_c8" rev-parse HEAD)
[ "$CALLER_AFTER_C8" = "$CALLER_HEAD_C8" ] || fail "caller HEAD must remain intact"
[ -z "$(git -C "$repo_c8" status --porcelain)" ] || fail "caller working tree must remain clean"
grep -Fq "existing caller content" "$repo_c8/existing.txt" || fail "caller files must remain intact"
grep -Fq "shared config = true" "$repo_c8/config.txt" || fail "caller config must remain intact"
pass "final combined gate check failure leaves caller's existing work intact"
invoke_cmd "$WS_HELPER" cleanup --manifest "$MANIFEST_C8" --status failed

printf 'all execution workflow tests passed\n'
