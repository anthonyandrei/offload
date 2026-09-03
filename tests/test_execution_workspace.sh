#!/usr/bin/env bash
# tests/test_execution_workspace.sh
# Lifecycle tests for scripts/execution-workspace.sh
# Verifies candidate isolation, scope enforcement, digest auditing,
# disposable preflight integration, and cleanup ownership guards.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/scripts/execution-workspace.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# Preflight: helper must exist and parse
[ -f "$HELPER" ] || fail "Helper script does not exist at $HELPER"
bash -n "$HELPER" || fail "Helper script does not parse"
[ -x "$HELPER" ] || fail "Helper script is not executable"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-test-exec-ws.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Helper to initialize a clean git repository
init_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.name "Test User"
  git -C "$repo_dir" config user.email "test@example.com"
  git -C "$repo_dir" config commit.gpgsign false
  git -C "$repo_dir" config core.autocrlf false
}

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT=0

invoke_helper() {
  local out_file="$TMP_ROOT/out.tmp"
  local err_file="$TMP_ROOT/err.tmp"
  rm -f "$out_file" "$err_file"

  set +e
  "$HELPER" "$@" > "$out_file" 2> "$err_file"
  RUN_EXIT=$?
  set -e

  RUN_STDOUT=$(cat "$out_file")
  RUN_STDERR=$(cat "$err_file")
}

# ===========================================================================
# 1. CLI validation & error handling
# ===========================================================================
invoke_helper
[ "$RUN_EXIT" -ne 0 ] || fail "missing command should fail"
pass "CLI requires command verb"

invoke_helper unknown-command
[ "$RUN_EXIT" -ne 0 ] || fail "unknown command should fail"
pass "CLI rejects unknown command verb"

invoke_helper create --help
[ "$RUN_EXIT" -eq 0 ] || fail "create --help should exit 0"
pass "CLI supports help flag"

# ===========================================================================
# 2. Two sibling tasks starting from same baseline
# ===========================================================================
ORIG_REPO="$TMP_ROOT/orig_repo"
init_repo "$ORIG_REPO"
printf 'base content\n' > "$ORIG_REPO/base.txt"
printf 'a initial\n' > "$ORIG_REPO/a.txt"
printf 'b initial\n' > "$ORIG_REPO/b.txt"
git -C "$ORIG_REPO" add .
git -C "$ORIG_REPO" commit -q -m "initial commit"
BASELINE=$(git -C "$ORIG_REPO" rev-parse HEAD | tr -d '\r\n')

SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH"

# Create Candidate A
MANIFEST_A="$SCRATCH/task-a.manifest.json"
invoke_helper create \
  --source-repo "$ORIG_REPO" \
  --task-id "task-a" \
  --baseline "$BASELINE" \
  --owned "a.txt" \
  --manifest "$MANIFEST_A"
[ "$RUN_EXIT" -eq 0 ] || fail "create task-a failed: $RUN_STDERR"
WS_A="$RUN_STDOUT"
[ -d "$WS_A" ] || fail "workspace A not created"
[ -f "$WS_A/.offload-execution-workspace" ] || fail "workspace A missing marker"
[ -f "$MANIFEST_A" ] || fail "manifest A not created"
pass "create candidate A succeeds and records marker"

# Create Candidate B
MANIFEST_B="$SCRATCH/task-b.manifest.json"
invoke_helper create \
  --source-repo "$ORIG_REPO" \
  --task-id "task-b" \
  --baseline "$BASELINE" \
  --owned "b.txt" \
  --manifest "$MANIFEST_B"
[ "$RUN_EXIT" -eq 0 ] || fail "create task-b failed: $RUN_STDERR"
WS_B="$RUN_STDOUT"
[ -d "$WS_B" ] || fail "workspace B not created"
[ -f "$WS_B/.offload-execution-workspace" ] || fail "workspace B missing marker"
pass "create candidate B succeeds at same baseline"

# Fake workers independently edit their owned files
# Worker A commits one change and leaves another uncommitted
printf 'a modified committed\n' > "$WS_A/a.txt"
git -C "$WS_A" commit -q -am "worker a commit"
printf 'a modified uncommitted line\n' >> "$WS_A/a.txt"

# Worker B modifies b.txt without committing
printf 'b modified uncommitted\n' > "$WS_B/b.txt"

# Verify-export Candidate A
invoke_helper verify-export --manifest "$MANIFEST_A"
[ "$RUN_EXIT" -eq 0 ] || fail "verify-export candidate A failed: $RUN_STDERR"
PATCH_A="$RUN_STDOUT"
[ -f "$PATCH_A" ] || fail "patch file A does not exist: $PATCH_A"
grep -q "a modified committed" "$PATCH_A" || fail "patch A missing committed change"
grep -q "a modified uncommitted line" "$PATCH_A" || fail "patch A missing uncommitted change"
pass "candidate A exports committed and uncommitted changes"

# Verify-export Candidate B
invoke_helper verify-export --manifest "$MANIFEST_B"
[ "$RUN_EXIT" -eq 0 ] || fail "verify-export candidate B failed: $RUN_STDERR"
PATCH_B="$RUN_STDOUT"
[ -f "$PATCH_B" ] || fail "patch file B does not exist: $PATCH_B"
grep -q "b modified uncommitted" "$PATCH_B" || fail "patch B missing uncommitted change"
pass "candidate B exports uncommitted changes independently"

# Integrate Candidate A into original repository
invoke_helper integrate --manifest "$MANIFEST_A" --target-repo "$ORIG_REPO"
[ "$RUN_EXIT" -eq 0 ] || fail "integrate candidate A failed: $RUN_STDERR"
grep -q "a modified uncommitted line" "$ORIG_REPO/a.txt" || fail "candidate A changes not applied to target"
pass "integrate candidate A applies changes to target repo"

# Commit Candidate A in target repo so working tree is clean for candidate B
git -C "$ORIG_REPO" commit -q -am "integrated task a"

# Integrate Candidate B into original repository
invoke_helper integrate --manifest "$MANIFEST_B" --target-repo "$ORIG_REPO"
[ "$RUN_EXIT" -eq 0 ] || fail "integrate candidate B failed: $RUN_STDERR"
grep -q "b modified uncommitted" "$ORIG_REPO/b.txt" || fail "candidate B changes not applied to target"
pass "integrate candidate B applies disjoint changes alongside candidate A"

# ===========================================================================
# 3. Scope violation blocks export and integration
# ===========================================================================
MANIFEST_BAD="$SCRATCH/task-bad.manifest.json"
invoke_helper create \
  --source-repo "$ORIG_REPO" \
  --task-id "task-bad" \
  --baseline "$BASELINE" \
  --owned "a.txt" \
  --frozen "base.txt" \
  --manifest "$MANIFEST_BAD"
[ "$RUN_EXIT" -eq 0 ] || fail "create task-bad failed: $RUN_STDERR"
WS_BAD="$RUN_STDOUT"

# Worker violates scope by modifying unowned file and frozen file
printf 'unowned mutation\n' > "$WS_BAD/b.txt"
printf 'frozen mutation\n' > "$WS_BAD/base.txt"
git -C "$WS_BAD" commit -q -am "violating commit"

invoke_helper verify-export --manifest "$MANIFEST_BAD"
[ "$RUN_EXIT" -ne 0 ] || fail "verify-export should fail on scope violation"
pass "scope violation (committed unowned and frozen changes) blocks verify-export"

# Integrate without export is rejected
invoke_helper integrate --manifest "$MANIFEST_BAD" --target-repo "$ORIG_REPO"
[ "$RUN_EXIT" -ne 0 ] || fail "integrate unexported candidate should fail"
pass "unexported candidate cannot be integrated"

# ===========================================================================
# 4. Content digest tampering detection
# ===========================================================================
# Tamper with PATCH_A and try to integrate into another clean repo
TAMPER_REPO="$TMP_ROOT/tamper_repo"
init_repo "$TAMPER_REPO"
printf 'base content\n' > "$TAMPER_REPO/base.txt"
printf 'a initial\n' > "$TAMPER_REPO/a.txt"
git -C "$TAMPER_REPO" add .
git -C "$TAMPER_REPO" commit -q -m "initial"

# Tamper patch file
printf '\n# injected tampering\n' >> "$PATCH_A"
invoke_helper integrate --manifest "$MANIFEST_A" --target-repo "$TAMPER_REPO"
[ "$RUN_EXIT" -ne 0 ] || fail "integrate tampered patch should fail"
printf '%s\n' "$RUN_STDERR" | grep -q "content digest mismatch" || fail "expected digest mismatch error"
pass "patch content digest mismatch blocks integration"

# ===========================================================================
# 5. Integration conflict in disposable checkout preflight
# ===========================================================================
CONFLICT_REPO="$TMP_ROOT/conflict_repo"
init_repo "$CONFLICT_REPO"
printf 'common line\n' > "$CONFLICT_REPO/conflict.txt"
git -C "$CONFLICT_REPO" add .
git -C "$CONFLICT_REPO" commit -q -m "initial"
C_BASE=$(git -C "$CONFLICT_REPO" rev-parse HEAD | tr -d '\r\n')

MANIFEST_C="$SCRATCH/task-c.manifest.json"
invoke_helper create \
  --source-repo "$CONFLICT_REPO" \
  --task-id "task-c" \
  --baseline "$C_BASE" \
  --owned "conflict.txt" \
  --manifest "$MANIFEST_C"
WS_C="$RUN_STDOUT"

# Candidate C changes conflict.txt
printf 'candidate change\n' > "$WS_C/conflict.txt"
invoke_helper verify-export --manifest "$MANIFEST_C"
[ "$RUN_EXIT" -eq 0 ] || fail "export candidate C failed: $RUN_STDERR"

# Target repo makes conflicting edit
printf 'conflicting caller change\n' > "$CONFLICT_REPO/conflict.txt"
git -C "$CONFLICT_REPO" commit -q -am "conflicting commit"

# Integration should preflight, fail, and leave CONFLICT_REPO untouched
invoke_helper integrate --manifest "$MANIFEST_C" --target-repo "$CONFLICT_REPO"
[ "$RUN_EXIT" -ne 0 ] || fail "integrate conflict should fail"
grep -q "conflicting caller change" "$CONFLICT_REPO/conflict.txt" || fail "target repo modified unexpectedly"
git -C "$CONFLICT_REPO" diff --exit-code >/dev/null || fail "target repo has dirty working tree"
pass "integration conflict detected in disposable checkout; caller repo left clean"

# ===========================================================================
# 6. Cleanup ownership guards
# ===========================================================================
# Attempting to clean CWD or repo root
invoke_helper cleanup --manifest "$MANIFEST_A" --status "retain"
[ "$RUN_EXIT" -eq 0 ] || fail "cleanup retain should exit 0"
[ -d "$WS_A" ] || fail "workspace A should be retained"
pass "cleanup with status retain preserves candidate worktree"

# Tamper manifest to point workspace_dir to ORIG_REPO
MANIFEST_ATTACK="$SCRATCH/attack.manifest.json"
cat <<EOF > "$MANIFEST_ATTACK"
{
  "schema_version": 1,
  "marker": "offload-execution-manifest-v1",
  "task_id": "attack",
  "source_repo": "$ORIG_REPO",
  "workspace_dir": "$ORIG_REPO",
  "baseline": "$BASELINE",
  "owned_paths": ["a.txt"],
  "frozen_paths": []
}
EOF

invoke_helper cleanup --manifest "$MANIFEST_ATTACK"
[ "$RUN_EXIT" -ne 0 ] || fail "cleanup must refuse to clean source repository"
[ -d "$ORIG_REPO" ] || fail "source repo was deleted"
pass "cleanup refuses to clean source repository checkout"

# Normal cleanup of Candidate A
invoke_helper cleanup --manifest "$MANIFEST_A" --status "success"
[ "$RUN_EXIT" -eq 0 ] || fail "normal cleanup failed: $RUN_STDERR"
[ ! -d "$WS_A" ] || fail "workspace A should be removed"
[ ! -f "$MANIFEST_A" ] || fail "manifest A should be removed"
pass "normal cleanup safely removes manifest-owned worktree"

printf 'all execution workspace tests passed\n'
