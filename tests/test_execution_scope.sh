#!/usr/bin/env bash
# tests/test_execution_scope.sh
# Acceptance tests for scripts/check-execution-scope.sh
# Verifies ownership, frozen paths, Git plumbing, renames, copies, spaces, and non-ASCII paths.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/scripts/check-execution-scope.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# Gate red-check: helper must exist and be executable
[ -f "$HELPER" ] || fail "Helper script does not exist at $HELPER"
bash -n "$HELPER" || fail "Helper script does not parse"
[ -x "$HELPER" ] || fail "Helper script is not executable"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-test-exec-scope.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Helper to initialize a clean git repository
init_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.name "Test User"
  git -C "$repo_dir" config user.email "test@example.com"
  git -C "$repo_dir" config commit.gpgsign false
}

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT=0

# Helper to invoke check-execution-scope.sh in a repository directory
invoke_scope() {
  local repo_dir="$1"
  shift
  local out_file="$TMP_ROOT/out.tmp"
  local err_file="$TMP_ROOT/err.tmp"
  rm -f "$out_file" "$err_file"

  set +e
  (cd "$repo_dir" && "$HELPER" "$@") > "$out_file" 2> "$err_file"
  RUN_EXIT=$?
  set -e

  RUN_STDOUT=$(cat "$out_file")
  RUN_STDERR=$(cat "$err_file")
}

invoke_scope_with_git_failure() {
  local repo_dir="$1"
  local fake_git_dir="$2"
  local failure_mode="$3"
  shift 3
  local out_file="$TMP_ROOT/out.tmp"
  local err_file="$TMP_ROOT/err.tmp"
  local real_git
  real_git=$(command -v git)
  rm -f "$out_file" "$err_file"

  set +e
  (cd "$repo_dir" && PATH="$fake_git_dir:$PATH" REAL_GIT="$real_git" FAKE_GIT_FAILURE="$failure_mode" "$HELPER" "$@") > "$out_file" 2> "$err_file"
  RUN_EXIT=$?
  set -e

  RUN_STDOUT=$(cat "$out_file")
  RUN_STDERR=$(cat "$err_file")
}

# ===========================================================================
# 1. CLI Argument and Environment Validation
# ===========================================================================

# 1.1 Fails when run outside a git worktree
non_git_dir="$TMP_ROOT/non_git"
mkdir -p "$non_git_dir"
invoke_scope "$non_git_dir" --owned "base.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "helper must fail outside of a git worktree"
pass "CLI rejects execution outside a git worktree"

# 1.2 Fails when no --owned arguments are provided
repo_clean="$TMP_ROOT/repo_clean"
init_repo "$repo_clean"
printf 'base content\n' > "$repo_clean/base.txt"
git -C "$repo_clean" add base.txt
git -C "$repo_clean" commit -m "initial commit" -q

invoke_scope "$repo_clean"
[ "$RUN_EXIT" -ne 0 ] || fail "helper must fail when no --owned argument is passed"
pass "CLI requires at least one --owned argument"

# 1.3 Fails on unknown arguments
invoke_scope "$repo_clean" --owned "base.txt" --unknown-option
[ "$RUN_EXIT" -ne 0 ] || fail "helper must fail on unknown arguments"
pass "CLI rejects unknown arguments"

# 1.4 Fails when --owned is passed without a value
invoke_scope "$repo_clean" --owned
[ "$RUN_EXIT" -ne 0 ] || fail "helper must fail when --owned has no value"
pass "CLI rejects --owned without value"

# ===========================================================================
# 2. Clean Repository ("Clean Success")
# ===========================================================================

invoke_scope "$repo_clean" --owned "base.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "clean repo should return 0"
[ -z "$RUN_STDOUT" ] || fail "clean repo should produce empty stdout"
pass "clean repository returns 0 and prints nothing"

invoke_scope "$repo_clean" --owned "base.txt" --frozen "base.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "clean repo with untouched frozen path should return 0"
[ -z "$RUN_STDOUT" ] || fail "clean repo with untouched frozen path should produce empty stdout"
pass "clean repository with untouched frozen path returns 0 and prints nothing"

# ===========================================================================
# 3. Owned File (Valid and Violation) & Partial Matching
# ===========================================================================

repo_files="$TMP_ROOT/repo_files"
init_repo "$repo_files"
printf 'content a\n' > "$repo_files/file_a.txt"
printf 'content b\n' > "$repo_files/file_b.txt"
git -C "$repo_files" add .
git -C "$repo_files" commit -m "initial files" -q

printf 'modified a\n' >> "$repo_files/file_a.txt"

# Valid: owned matches touched file exactly
invoke_scope "$repo_files" --owned "file_a.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "owned modified file should return 0"
[ -z "$RUN_STDOUT" ] || fail "owned modified file should produce empty stdout"
pass "owned modified file passes"

# Violation: modified file is not owned
invoke_scope "$repo_files" --owned "file_b.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "unowned modified file should return nonzero"
grep -Fq "file_a.txt" <<< "$RUN_STDOUT" || fail "stdout must list file_a.txt violation"
pass "unowned modified file returns nonzero and prints path"

# Partial match: file_a must not match file_a.txt
invoke_scope "$repo_files" --owned "file_a"
[ "$RUN_EXIT" -ne 0 ] || fail "partial filename match must not satisfy ownership"
grep -Fq "file_a.txt" <<< "$RUN_STDOUT" || fail "stdout must list file_a.txt on partial match"
pass "partial filename prefix does not satisfy file ownership"

# ===========================================================================
# 4. Owned Directory (Valid, Trailing Slash, Boundary Checks)
# ===========================================================================

repo_dirs="$TMP_ROOT/repo_dirs"
init_repo "$repo_dirs"
mkdir -p "$repo_dirs/src/components" "$repo_dirs/src-extra"
printf 'app\n' > "$repo_dirs/src/app.txt"
printf 'btn\n' > "$repo_dirs/src/components/button.txt"
printf 'extra\n' > "$repo_dirs/src-extra/file.txt"
git -C "$repo_dirs" add .
git -C "$repo_dirs" commit -m "initial dirs" -q

printf 'mod app\n' >> "$repo_dirs/src/app.txt"
printf 'mod btn\n' >> "$repo_dirs/src/components/button.txt"

# Valid: owned directory without trailing slash
invoke_scope "$repo_dirs" --owned "src"
[ "$RUN_EXIT" -eq 0 ] || fail "owned directory without trailing slash should return 0"
[ -z "$RUN_STDOUT" ] || fail "owned directory should produce empty stdout"
pass "owned directory without trailing slash covers contained files"

# Valid: owned directory with trailing slash
invoke_scope "$repo_dirs" --owned "src/"
[ "$RUN_EXIT" -eq 0 ] || fail "owned directory with trailing slash should return 0"
[ -z "$RUN_STDOUT" ] || fail "owned directory with trailing slash should produce empty stdout"
pass "owned directory with trailing slash covers contained files"

# Violation: nested directory does not cover parent directory files
invoke_scope "$repo_dirs" --owned "src/components"
[ "$RUN_EXIT" -ne 0 ] || fail "src/components should not cover src/app.txt"
grep -Fq "src/app.txt" <<< "$RUN_STDOUT" || fail "stdout must list src/app.txt"
pass "nested directory scope does not cover parent directory files"

# Boundary check: src must NOT match src-extra
printf 'mod extra\n' >> "$repo_dirs/src-extra/file.txt"
invoke_scope "$repo_dirs" --owned "src"
[ "$RUN_EXIT" -ne 0 ] || fail "owned dir src must not match src-extra"
grep -Fq "src-extra/file.txt" <<< "$RUN_STDOUT" || fail "stdout must list src-extra/file.txt"
pass "owned directory respects boundary and rejects prefix-sharing sibling"

# ===========================================================================
# 5. Multiple Repeated --owned Arguments
# ===========================================================================

repo_multi="$TMP_ROOT/repo_multi"
init_repo "$repo_multi"
mkdir -p "$repo_multi/docs" "$repo_multi/src"
printf 'doc\n' > "$repo_multi/docs/guide.md"
printf 'code\n' > "$repo_multi/src/code.py"
printf 'config\n' > "$repo_multi/config.json"
git -C "$repo_multi" add .
git -C "$repo_multi" commit -m "initial multi" -q

printf 'mod doc\n' >> "$repo_multi/docs/guide.md"
printf 'mod code\n' >> "$repo_multi/src/code.py"

# Valid: both paths owned
invoke_scope "$repo_multi" --owned "docs" --owned "src/code.py"
[ "$RUN_EXIT" -eq 0 ] || fail "multiple --owned arguments should succeed"
[ -z "$RUN_STDOUT" ] || fail "multiple --owned stdout should be empty"
pass "multiple repeated --owned arguments succeed"

# Violation: omitted path
invoke_scope "$repo_multi" --owned "docs"
[ "$RUN_EXIT" -ne 0 ] || fail "omitted owned path should fail"
grep -Fq "src/code.py" <<< "$RUN_STDOUT" || fail "stdout must list unowned src/code.py"
pass "omitted owned path among multiple changes reports violation"

# ===========================================================================
# 6. Frozen File
# ===========================================================================

repo_frozen="$TMP_ROOT/repo_frozen"
init_repo "$repo_frozen"
mkdir -p "$repo_frozen/config"
printf 'allowed\n' > "$repo_frozen/config/allowed.txt"
printf 'secret\n' > "$repo_frozen/config/secret.txt"
git -C "$repo_frozen" add .
git -C "$repo_frozen" commit -m "initial frozen" -q

# Case A: Untouched frozen file
printf 'mod allowed\n' >> "$repo_frozen/config/allowed.txt"
invoke_scope "$repo_frozen" --owned "config" --frozen "config/secret.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "untouched frozen file should succeed"
[ -z "$RUN_STDOUT" ] || fail "untouched frozen file should produce empty stdout"
pass "untouched frozen file does not trigger violation"

# Case B: Modified frozen file (even when owned)
printf 'mod secret\n' >> "$repo_frozen/config/secret.txt"
invoke_scope "$repo_frozen" --owned "config" --frozen "config/secret.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "modified frozen file must fail even if in owned directory"
grep -Fq "config/secret.txt" <<< "$RUN_STDOUT" || fail "stdout must list frozen config/secret.txt"
pass "modified frozen file reports violation even when covered by --owned"

# ===========================================================================
# 7. Frozen Directory
# ===========================================================================

repo_frozendir="$TMP_ROOT/repo_frozendir"
init_repo "$repo_frozendir"
mkdir -p "$repo_frozendir/legacy/sub" "$repo_frozendir/legacy-v2"
printf 'old\n' > "$repo_frozendir/legacy/sub/old.txt"
printf 'new\n' > "$repo_frozendir/legacy-v2/new.txt"
git -C "$repo_frozendir" add .
git -C "$repo_frozendir" commit -m "initial frozen dir" -q

printf 'mod old\n' >> "$repo_frozendir/legacy/sub/old.txt"

# Violation: file in frozen directory
invoke_scope "$repo_frozendir" --owned "legacy" --frozen "legacy"
[ "$RUN_EXIT" -ne 0 ] || fail "modified file inside frozen directory must fail"
grep -Fq "legacy/sub/old.txt" <<< "$RUN_STDOUT" || fail "stdout must list legacy/sub/old.txt"
pass "modified file inside frozen directory reports violation"

# Frozen directory with trailing slash
invoke_scope "$repo_frozendir" --owned "legacy" --frozen "legacy/"
[ "$RUN_EXIT" -ne 0 ] || fail "frozen dir with trailing slash must fail"
grep -Fq "legacy/sub/old.txt" <<< "$RUN_STDOUT" || fail "stdout must list legacy/sub/old.txt"
pass "frozen directory with trailing slash reports violation"

# Boundary check: legacy must NOT freeze legacy-v2
git -C "$repo_frozendir" checkout -q legacy/sub/old.txt
printf 'mod new\n' >> "$repo_frozendir/legacy-v2/new.txt"
invoke_scope "$repo_frozendir" --owned "legacy-v2" --frozen "legacy"
[ "$RUN_EXIT" -eq 0 ] || fail "frozen directory must not freeze sibling directory"
[ -z "$RUN_STDOUT" ] || fail "frozen directory sibling should produce empty stdout"
pass "frozen directory respects boundary and does not freeze prefix-sharing sibling"

# ===========================================================================
# 8. Modified Tracked Files (Staged and Unstaged)
# ===========================================================================

repo_mod="$TMP_ROOT/repo_mod"
init_repo "$repo_mod"
printf 'staged\n' > "$repo_mod/staged.txt"
printf 'unstaged\n' > "$repo_mod/unstaged.txt"
git -C "$repo_mod" add .
git -C "$repo_mod" commit -m "initial mod" -q

printf 'mod unstaged\n' >> "$repo_mod/unstaged.txt"
printf 'mod staged\n' >> "$repo_mod/staged.txt"
git -C "$repo_mod" add staged.txt

# Both owned
invoke_scope "$repo_mod" --owned "staged.txt" --owned "unstaged.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "both staged and unstaged owned should succeed"
[ -z "$RUN_STDOUT" ] || fail "both staged and unstaged owned stdout should be empty"
pass "modified tracked files (both staged and unstaged) pass when owned"

# Missing unstaged
invoke_scope "$repo_mod" --owned "staged.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "unowned unstaged modification must fail"
grep -Fq "unstaged.txt" <<< "$RUN_STDOUT" || fail "stdout must list unstaged.txt"
pass "unowned unstaged modification reports violation"

# Missing staged
invoke_scope "$repo_mod" --owned "unstaged.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "unowned staged modification must fail"
grep -Fq "staged.txt" <<< "$RUN_STDOUT" || fail "stdout must list staged.txt"
pass "unowned staged modification reports violation"

# ===========================================================================
# 9. Deleted Tracked Files (Staged and Unstaged, and Frozen)
# ===========================================================================

repo_del="$TMP_ROOT/repo_del"
init_repo "$repo_del"
printf 'del1\n' > "$repo_del/del_staged.txt"
printf 'del2\n' > "$repo_del/del_unstaged.txt"
git -C "$repo_del" add .
git -C "$repo_del" commit -m "initial del" -q

rm "$repo_del/del_unstaged.txt"
git -C "$repo_del" rm -q del_staged.txt

# Both owned
invoke_scope "$repo_del" --owned "del_staged.txt" --owned "del_unstaged.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "deleted tracked files should succeed when owned"
[ -z "$RUN_STDOUT" ] || fail "deleted tracked files should produce empty stdout"
pass "deleted tracked files (staged and unstaged) pass when owned"

# Unowned unstaged delete
invoke_scope "$repo_del" --owned "del_staged.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "unowned unstaged deletion must fail"
grep -Fq "del_unstaged.txt" <<< "$RUN_STDOUT" || fail "stdout must list del_unstaged.txt"
pass "unowned unstaged deletion reports violation"

# Frozen deleted file
invoke_scope "$repo_del" --owned "del_staged.txt" --owned "del_unstaged.txt" --frozen "del_unstaged.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "frozen deleted file must fail"
grep -Fq "del_unstaged.txt" <<< "$RUN_STDOUT" || fail "stdout must list frozen deleted file"
pass "frozen deleted file reports violation"

# ===========================================================================
# 10. Renamed Files (Both Paths Involved)
# ===========================================================================

repo_rename="$TMP_ROOT/repo_rename"
init_repo "$repo_rename"
printf 'line 1\nline 2\nline 3\n' > "$repo_rename/old_path.txt"
git -C "$repo_rename" add .
git -C "$repo_rename" commit -m "initial rename" -q

git -C "$repo_rename" mv old_path.txt new_path.txt

# Both paths owned
invoke_scope "$repo_rename" --owned "old_path.txt" --owned "new_path.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "renamed file with both paths owned should succeed"
[ -z "$RUN_STDOUT" ] || fail "renamed file with both paths owned stdout should be empty"
pass "renamed file with both paths owned passes"

# Only new path owned: old path violation
invoke_scope "$repo_rename" --owned "new_path.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "renamed file with only new path owned must fail"
grep -Fq "old_path.txt" <<< "$RUN_STDOUT" || fail "stdout must list old_path.txt"
pass "renamed file missing old path reports violation"

# Only old path owned: new path violation
invoke_scope "$repo_rename" --owned "old_path.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "renamed file with only old path owned must fail"
grep -Fq "new_path.txt" <<< "$RUN_STDOUT" || fail "stdout must list new_path.txt"
pass "renamed file missing new path reports violation"

# Frozen old path: fails
invoke_scope "$repo_rename" --owned "old_path.txt" --owned "new_path.txt" --frozen "old_path.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "renamed file with frozen old path must fail"
grep -Fq "old_path.txt" <<< "$RUN_STDOUT" || fail "stdout must list frozen old_path.txt"
pass "renamed file with frozen old path reports violation"

# Frozen new path: fails
invoke_scope "$repo_rename" --owned "old_path.txt" --owned "new_path.txt" --frozen "new_path.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "renamed file with frozen new path must fail"
grep -Fq "new_path.txt" <<< "$RUN_STDOUT" || fail "stdout must list frozen new_path.txt"
pass "renamed file with frozen new path reports violation"

# ===========================================================================
# 11. Copied Files
# ===========================================================================

repo_copy="$TMP_ROOT/repo_copy"
init_repo "$repo_copy"
printf 'seed 1\nseed 2\nseed 3\n' > "$repo_copy/orig.txt"
git -C "$repo_copy" add .
git -C "$repo_copy" commit -m "initial copy" -q

cp "$repo_copy/orig.txt" "$repo_copy/copy.txt"
git -C "$repo_copy" add copy.txt

# Both paths owned
invoke_scope "$repo_copy" --owned "orig.txt" --owned "copy.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "copied file with both paths owned should succeed"
[ -z "$RUN_STDOUT" ] || fail "copied file with both paths owned stdout should be empty"
pass "copied file passes when copy is owned"

# Unowned copy
invoke_scope "$repo_copy" --owned "orig.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "unowned copied file must fail"
grep -Fq "copy.txt" <<< "$RUN_STDOUT" || fail "stdout must list copy.txt"
pass "unowned copied file reports violation"

# Frozen copy
invoke_scope "$repo_copy" --owned "orig.txt" --owned "copy.txt" --frozen "copy.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "frozen copied file must fail"
grep -Fq "copy.txt" <<< "$RUN_STDOUT" || fail "stdout must list frozen copy.txt"
pass "frozen copied file reports violation"

# ===========================================================================
# 12. Untracked Files (Not Ignored)
# ===========================================================================

repo_untracked="$TMP_ROOT/repo_untracked"
init_repo "$repo_untracked"
printf 'base\n' > "$repo_untracked/base.txt"
git -C "$repo_untracked" add .
git -C "$repo_untracked" commit -m "initial untracked" -q

printf 'new untracked\n' > "$repo_untracked/new_untracked.txt"
mkdir -p "$repo_untracked/untracked_dir"
printf 'nested untracked\n' > "$repo_untracked/untracked_dir/nested.txt"

# Valid: both owned
invoke_scope "$repo_untracked" --owned "new_untracked.txt" --owned "untracked_dir"
[ "$RUN_EXIT" -eq 0 ] || fail "owned untracked files should succeed"
[ -z "$RUN_STDOUT" ] || fail "owned untracked files stdout should be empty"
pass "untracked files pass when owned"

# Violation: unowned untracked file
invoke_scope "$repo_untracked" --owned "base.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "unowned untracked file must fail"
grep -Fq "new_untracked.txt" <<< "$RUN_STDOUT" || fail "stdout must list new_untracked.txt"
grep -Fq "untracked_dir/nested.txt" <<< "$RUN_STDOUT" || fail "stdout must list untracked_dir/nested.txt"
pass "unowned untracked files report violation"

# Frozen untracked file
invoke_scope "$repo_untracked" --owned "new_untracked.txt" --owned "untracked_dir" --frozen "new_untracked.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "frozen untracked file must fail"
grep -Fq "new_untracked.txt" <<< "$RUN_STDOUT" || fail "stdout must list frozen untracked file"
pass "frozen untracked file reports violation"

# ===========================================================================
# 13. Ignored Files
# ===========================================================================

repo_ignored="$TMP_ROOT/repo_ignored"
init_repo "$repo_ignored"
printf '*.log\ntemp/\n' > "$repo_ignored/.gitignore"
printf 'base\n' > "$repo_ignored/base.txt"
git -C "$repo_ignored" add .
git -C "$repo_ignored" commit -m "initial gitignore" -q

printf 'log output\n' > "$repo_ignored/debug.log"
mkdir -p "$repo_ignored/temp"
printf 'temp data\n' > "$repo_ignored/temp/scratch.txt"

# Ignored files must not trigger violations
invoke_scope "$repo_ignored" --owned "base.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "ignored files must not cause violation"
[ -z "$RUN_STDOUT" ] || fail "ignored files stdout must be empty"
pass "ignored files are excluded from scope violations"

# ===========================================================================
# 14. Spaced Paths
# ===========================================================================

repo_spaces="$TMP_ROOT/repo_spaces"
init_repo "$repo_spaces"
mkdir -p "$repo_spaces/folder with spaces"
printf 'spaced file\n' > "$repo_spaces/folder with spaces/file with spaces.txt"
git -C "$repo_spaces" add .
git -C "$repo_spaces" commit -m "initial spaces" -q

printf 'modified spaced\n' >> "$repo_spaces/folder with spaces/file with spaces.txt"
printf 'untracked spaced\n' > "$repo_spaces/another spaced file.txt"

# Valid: both owned
invoke_scope "$repo_spaces" --owned "folder with spaces" --owned "another spaced file.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "spaced paths within owned scope should succeed"
[ -z "$RUN_STDOUT" ] || fail "spaced paths stdout should be empty"
pass "spaced paths pass when owned"

# Violation: unowned spaced file
invoke_scope "$repo_spaces" --owned "folder with spaces"
[ "$RUN_EXIT" -ne 0 ] || fail "unowned spaced file must fail"
grep -Fq "another spaced file.txt" <<< "$RUN_STDOUT" || fail "stdout must list unowned spaced file"
pass "unowned spaced path reports violation"

# Frozen spaced file
invoke_scope "$repo_spaces" --owned "folder with spaces" --owned "another spaced file.txt" --frozen "folder with spaces/file with spaces.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "frozen spaced file must fail"
grep -Fq "folder with spaces/file with spaces.txt" <<< "$RUN_STDOUT" || fail "stdout must list frozen spaced path"
pass "frozen spaced path reports violation"

# ===========================================================================
# 15. Non-ASCII Paths
# ===========================================================================

repo_nonascii="$TMP_ROOT/repo_nonascii"
init_repo "$repo_nonascii"
mkdir -p "$repo_nonascii/dossier"
printf 'café\n' > "$repo_nonascii/dossier/café.txt"
printf 'résumé\n' > "$repo_nonascii/résumé.md"
git -C "$repo_nonascii" add .
git -C "$repo_nonascii" commit -m "initial non-ascii" -q

printf 'mod café\n' >> "$repo_nonascii/dossier/café.txt"
mkdir -p "$repo_nonascii/münchen"
printf 'stadt\n' > "$repo_nonascii/münchen/stadt.txt"

# Valid: all owned
invoke_scope "$repo_nonascii" --owned "dossier" --owned "résumé.md" --owned "münchen"
[ "$RUN_EXIT" -eq 0 ] || fail "non-ASCII paths within owned scope should succeed"
[ -z "$RUN_STDOUT" ] || fail "non-ASCII paths stdout should be empty"
pass "non-ASCII paths pass when owned"

# Violation: unowned non-ASCII path
invoke_scope "$repo_nonascii" --owned "dossier" --owned "résumé.md"
[ "$RUN_EXIT" -ne 0 ] || fail "unowned non-ASCII path must fail"
grep -Fq "münchen/stadt.txt" <<< "$RUN_STDOUT" || fail "stdout must list unowned non-ASCII path münchen/stadt.txt"
pass "unowned non-ASCII path reports violation"

# Frozen non-ASCII path
invoke_scope "$repo_nonascii" --owned "dossier" --owned "résumé.md" --owned "münchen" --frozen "dossier/café.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "frozen non-ASCII path must fail"
grep -Fq "dossier/café.txt" <<< "$RUN_STDOUT" || fail "stdout must list frozen non-ASCII path dossier/café.txt"
pass "frozen non-ASCII path reports violation"

# ===========================================================================
# 16. Baseline-Relative Committed Changes
# ===========================================================================

repo_baseline="$TMP_ROOT/repo_baseline"
init_repo "$repo_baseline"
printf 'owned base\n' > "$repo_baseline/owned.txt"
printf 'frozen base\n' > "$repo_baseline/frozen.txt"
git -C "$repo_baseline" add .
git -C "$repo_baseline" commit -m "baseline" -q
baseline_revision=$(git -C "$repo_baseline" rev-parse HEAD)
printf 'unowned\n' > "$repo_baseline/unowned-committed.txt"
git -C "$repo_baseline" add .
git -C "$repo_baseline" commit -m "unowned committed edit" -q
printf 'committed frozen edit\n' >> "$repo_baseline/frozen.txt"
git -C "$repo_baseline" add .
git -C "$repo_baseline" commit -m "frozen committed edit" -q
invoke_scope "$repo_baseline" --baseline "$baseline_revision" --owned owned.txt --frozen frozen.txt
[ "$RUN_EXIT" -ne 0 ] || fail "baseline must detect committed changes with clean status"
grep -Fq "unowned-committed.txt" <<< "$RUN_STDOUT" || fail "baseline stdout must list committed unowned path"
grep -Fq "frozen.txt" <<< "$RUN_STDOUT" || fail "baseline stdout must list committed frozen path"
pass "baseline detects committed changes with clean status"
invoke_scope "$repo_baseline" --baseline does-not-exist --owned owned.txt
[ "$RUN_EXIT" -ne 0 ] || fail "invalid baseline must return nonzero"
pass "invalid baseline returns nonzero"

fake_git_dir="$TMP_ROOT/fake-git-status"
mkdir -p "$fake_git_dir"
cat > "$fake_git_dir/git" <<'EOF'
#!/usr/bin/env bash
if [ "${FAKE_GIT_FAILURE:-}" = "status" ]; then
  for arg in "$@"; do
    if [ "$arg" = "status" ]; then
      printf '%s\n' "simulated status failure" >&2
      exit 73
    fi
  done
fi
if [ "${FAKE_GIT_FAILURE:-}" = "diff" ]; then
  for arg in "$@"; do
    if [ "$arg" = "diff" ]; then
      printf '%s\n' "simulated diff failure" >&2
      exit 74
    fi
  done
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$fake_git_dir/git"
invoke_scope_with_git_failure "$repo_baseline" "$fake_git_dir" status --owned owned.txt
[ "$RUN_EXIT" -eq 73 ] || fail "git status failure must preserve exit code 73"
grep -Fq "status" <<< "$RUN_STDERR" || fail "git status failure must name the operation"
pass "mocked git status failure is reported"
invoke_scope_with_git_failure "$repo_baseline" "$fake_git_dir" diff --baseline "$baseline_revision" --owned owned.txt
[ "$RUN_EXIT" -eq 74 ] || fail "git diff failure must preserve exit code 74"
grep -Fq "diff" <<< "$RUN_STDERR" || fail "git diff failure must name the operation"
pass "mocked git diff failure is reported"

# Baseline renames and deletions must include every affected path.
repo_baseline_paths="$TMP_ROOT/repo_baseline_paths"
init_repo "$repo_baseline_paths"
printf 'rename me\n' > "$repo_baseline_paths/rename-old.txt"
printf 'delete me\n' > "$repo_baseline_paths/delete-me.txt"
printf 'unchanged\n' > "$repo_baseline_paths/unrelated.txt"
git -C "$repo_baseline_paths" add .
git -C "$repo_baseline_paths" commit -m "baseline paths" -q
baseline_paths_revision=$(git -C "$repo_baseline_paths" rev-parse HEAD)
git -C "$repo_baseline_paths" mv rename-old.txt rename-new.txt
git -C "$repo_baseline_paths" rm delete-me.txt -q
git -C "$repo_baseline_paths" commit -m "rename and delete" -q
invoke_scope "$repo_baseline_paths" --baseline "$baseline_paths_revision" --owned unrelated.txt --frozen delete-me.txt
[ "$RUN_EXIT" -ne 0 ] || fail "baseline must detect renames and deletions"
grep -Fq "rename-old.txt" <<< "$RUN_STDOUT" || fail "baseline stdout must list the old rename path"
grep -Fq "rename-new.txt" <<< "$RUN_STDOUT" || fail "baseline stdout must list the new rename path"
grep -Fq "delete-me.txt" <<< "$RUN_STDOUT" || fail "baseline stdout must list the deleted path"
pass "baseline reports every rename and deletion path"

# ===========================================================================
# 18. Valid Scope Prints Nothing and Creates No Comparison Files
# ===========================================================================

repo_cleanliness="$TMP_ROOT/repo_cleanliness"
init_repo "$repo_cleanliness"
printf 'tracked\n' > "$repo_cleanliness/tracked.txt"
git -C "$repo_cleanliness" add .
git -C "$repo_cleanliness" commit -m "initial cleanliness" -q

printf 'modified\n' >> "$repo_cleanliness/tracked.txt"
printf 'new\n' > "$repo_cleanliness/new_owned.txt"

# Capture porcelain status before running
status_before=$(git -C "$repo_cleanliness" status --porcelain -uall)

invoke_scope "$repo_cleanliness" --owned "tracked.txt" --owned "new_owned.txt"
[ "$RUN_EXIT" -eq 0 ] || fail "valid scope check should succeed"
[ -z "$RUN_STDOUT" ] || fail "valid scope check must produce empty stdout"

status_after=$(git -C "$repo_cleanliness" status --porcelain -uall)
[ "$status_before" = "$status_after" ] || fail "scope check must not alter git status"

# Verify no extra files created in repo
for f in "$repo_cleanliness"/* "$repo_cleanliness"/.*; do
  base_f=$(basename "$f")
  case "$base_f" in
    .|..|.git|tracked.txt|new_owned.txt) ;;
    *) fail "unexpected file created in repository worktree: $base_f" ;;
  esac
done
pass "valid scope prints nothing, modifies no status, and creates no comparison files"

# ===========================================================================
# 17. Violations Print Each Violating Path and Return Nonzero
# ===========================================================================

repo_violations="$TMP_ROOT/repo_violations"
init_repo "$repo_violations"
printf 'clean file\n' > "$repo_violations/clean.txt"
printf 'frozen base\n' > "$repo_violations/frozen_file.txt"
git -C "$repo_violations" add .
git -C "$repo_violations" commit -m "initial violations" -q

printf 'unowned 1\n' > "$repo_violations/unowned_one.txt"
printf 'unowned 2\n' > "$repo_violations/unowned_two.txt"
printf 'mod frozen\n' >> "$repo_violations/frozen_file.txt"

status_viol_before=$(git -C "$repo_violations" status --porcelain -uall)

invoke_scope "$repo_violations" --owned "clean.txt" --frozen "frozen_file.txt"
[ "$RUN_EXIT" -ne 0 ] || fail "violations must produce nonzero exit code"
grep -Fq "unowned_one.txt" <<< "$RUN_STDOUT" || fail "stdout must list unowned_one.txt"
grep -Fq "unowned_two.txt" <<< "$RUN_STDOUT" || fail "stdout must list unowned_two.txt"
grep -Fq "frozen_file.txt" <<< "$RUN_STDOUT" || fail "stdout must list frozen_file.txt"

status_viol_after=$(git -C "$repo_violations" status --porcelain -uall)
[ "$status_viol_before" = "$status_viol_after" ] || fail "failed scope check must not alter git status"

# Verify no comparison files left on failure either
for f in "$repo_violations"/* "$repo_violations"/.*; do
  base_f=$(basename "$f")
  case "$base_f" in
    .|..|.git|clean.txt|frozen_file.txt|unowned_one.txt|unowned_two.txt) ;;
    *) fail "unexpected file created in repository worktree on failure: $base_f" ;;
  esac
done
pass "violations print each violating path to stdout and return nonzero without creating comparison files"

printf '%s\n' "all execution scope checks passed"
