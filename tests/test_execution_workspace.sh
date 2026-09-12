#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
helper="$root/scripts/execution-workspace.sh"
temp_root=$(mktemp -d "/tmp/offload-exec-sh.XXXXXX")
trap 'rm -rf -- "$temp_root"' EXIT
total=0

pass() { total=$((total + 1)); printf 'ok - %s\n' "$1"; }
assert_true() { local value=$2 name=$3; [[ "$value" = true ]] || { printf 'FAIL: %s\n' "$name" >&2; exit 1; }; pass "$name"; }

repo="$temp_root/repo"
workspace_parent="$temp_root/offload-exec-explicit"
workspace="$workspace_parent/checkout"
mkdir -p -- "$repo" "$workspace_parent"
git -C "$repo" init -q
git -C "$repo" config user.name 'Test User'
git -C "$repo" config user.email 'test@example.com'
printf 'owned\n' > "$repo/owned.txt"
printf 'unowned\n' > "$repo/unowned.txt"
git -C "$repo" add .
git -C "$repo" commit -q -m initial
baseline=$(git -C "$repo" rev-parse HEAD)

if output=$(OFFLOAD_WORKER_CONTEXT=1 bash "$helper" create --source-repo "$repo" --task-id worker --baseline "$baseline" --workspace "$temp_root/worker-checkout"); then worker_create_code=0; else worker_create_code=$?; fi
assert_true test "$( [ "$worker_create_code" -ne 0 ] && printf true || printf false )" 'worker context cannot create an execution workspace'

if output=$(bash "$helper" create --source-repo "$repo" --task-id acceptance --baseline "$baseline" --workspace "$workspace"); then create_code=0; else create_code=$?; fi
assert_true test "$( [ "$create_code" -eq 0 ] && printf true || printf false )" 'create makes a worktree'
assert_true test "$( [ -d "$workspace" ] && printf true || printf false )" 'workspace exists'
assert_true test "$( [ -f "$workspace/.offload-execution-workspace" ] && printf true || printf false )" 'workspace has a disposable marker'
assert_true test "$( git -C "$repo" worktree list --porcelain | grep -Eq 'worktree .*[\\\\/]checkout$' && printf true || printf false )" 'workspace is registered with Git'

printf 'owned changed\n' > "$workspace/owned.txt"
if output=$(bash "$helper" check --workspace "$workspace" --baseline "$baseline" --owned owned.txt); then owned_code=0; else owned_code=$?; fi
assert_true test "$( [ "$owned_code" -eq 0 ] && printf true || printf false )" 'owned worktree change passes scope check'

printf 'unowned changed\n' > "$workspace/unowned.txt"
if output=$(bash "$helper" check --workspace "$workspace" --baseline "$baseline" --owned owned.txt); then unowned_code=0; else unowned_code=$?; fi
assert_true test "$( [ "$unowned_code" -ne 0 ] && printf true || printf false )" 'unowned worktree change fails scope check'

printf 'unowned\n' > "$workspace/unowned.txt"
if output=$(bash "$helper" cleanup --source-repo "$repo" --workspace "$workspace" --retain); then retain_code=0; else retain_code=$?; fi
assert_true test "$( [ "$retain_code" -eq 0 ] && printf true || printf false )" 'retain leaves a valid workspace in place'
assert_true test "$( [ -d "$workspace" ] && printf true || printf false )" 'retained workspace remains available for review'

if output=$(OFFLOAD_WORKER_CONTEXT=1 bash "$helper" cleanup --source-repo "$repo" --workspace "$workspace"); then worker_cleanup_code=0; else worker_cleanup_code=$?; fi
assert_true test "$( [ "$worker_cleanup_code" -ne 0 ] && printf true || printf false )" 'worker context cannot remove an execution workspace'

if output=$(bash "$helper" cleanup --source-repo "$repo" --workspace "$workspace"); then cleanup_code=0; else cleanup_code=$?; fi
assert_true test "$( [ "$cleanup_code" -eq 0 ] && printf true || printf false )" 'cleanup removes a marked registered worktree'
assert_true test "$( [ ! -e "$workspace" ] && printf true || printf false )" 'cleaned workspace is gone'
assert_true test "$( [ -d "$workspace_parent" ] && printf true || printf false )" 'explicit workspace parent is preserved'

generated_workspace=$(bash "$helper" create --source-repo "$repo" --task-id generated --baseline "$baseline")
generated_parent=$(dirname -- "$generated_workspace")
if output=$(bash "$helper" cleanup --source-repo "$repo" --workspace "$generated_workspace"); then generated_cleanup_code=0; else generated_cleanup_code=$?; fi
assert_true test "$( [ "$generated_cleanup_code" -eq 0 ] && printf true || printf false )" 'cleanup removes a generated execution workspace'
assert_true test "$( [ ! -e "$generated_workspace" ] && printf true || printf false )" 'generated execution workspace is verified gone'
assert_true test "$( [ ! -e "$generated_parent" ] && printf true || printf false )" 'generated execution workspace parent is verified gone'

leftover_workspace=$(bash "$helper" create --source-repo "$repo" --task-id leftover --baseline "$baseline")
leftover_parent=$(dirname -- "$leftover_workspace")
printf 'leftover\n' > "$leftover_parent/leftover.txt"
cleanup_error="$temp_root/execution-cleanup-error"
if output=$(bash "$helper" cleanup --source-repo "$repo" --workspace "$leftover_workspace" 2>"$cleanup_error"); then leftover_cleanup_code=0; else leftover_cleanup_code=$?; fi
assert_true test "$( [ "$leftover_cleanup_code" -ne 0 ] && printf true || printf false )" 'cleanup fails when the generated parent remains'
assert_true test "$( grep -Fq -- "$leftover_parent" "$cleanup_error" && printf true || printf false )" 'execution cleanup failure names the leftover parent'
assert_true test "$( [ ! -e "$leftover_workspace" ] && printf true || printf false )" 'failed execution cleanup still removes the worktree'
assert_true test "$( [ -e "$leftover_parent" ] && printf true || printf false )" 'failed execution cleanup preserves the leftover parent'
rm -rf -- "$leftover_parent"

unmarked="$temp_root/unmarked"
mkdir -p -- "$unmarked"
if output=$(bash "$helper" cleanup --source-repo "$repo" --workspace "$unmarked"); then rejected_code=0; else rejected_code=$?; fi
assert_true test "$( [ "$rejected_code" -ne 0 ] && printf true || printf false )" 'cleanup rejects an unmarked directory'
assert_true test "$( [ -d "$unmarked" ] && printf true || printf false )" 'rejected directory is preserved'

unregistered="$temp_root/unregistered"
mkdir -p -- "$unregistered"
printf 'offload-execution-workspace-v2\n' > "$unregistered/.offload-execution-workspace"
if output=$(bash "$helper" cleanup --source-repo "$repo" --workspace "$unregistered"); then unregistered_code=0; else unregistered_code=$?; fi
assert_true test "$( [ "$unregistered_code" -ne 0 ] && printf true || printf false )" 'cleanup rejects an unregistered marked directory'
assert_true test "$( [ -d "$unregistered" ] && printf true || printf false )" 'unregistered directory is preserved'

if output=$(bash "$helper" cleanup --source-repo "$repo" --workspace "$repo"); then source_cleanup_code=0; else source_cleanup_code=$?; fi
assert_true test "$( [ "$source_cleanup_code" -ne 0 ] && printf true || printf false )" 'cleanup rejects the live source repository'
assert_true test "$( [ -d "$repo" ] && printf true || printf false )" 'live source repository is preserved'

printf 'all bash execution workspace checks passed (%s tests)\n' "$total"
