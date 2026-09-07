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
workspace="$temp_root/checkout"
mkdir -p -- "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name 'Test User'
git -C "$repo" config user.email 'test@example.com'
printf 'owned\n' > "$repo/owned.txt"
printf 'unowned\n' > "$repo/unowned.txt"
git -C "$repo" add .
git -C "$repo" commit -q -m initial
baseline=$(git -C "$repo" rev-parse HEAD)

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

if output=$(bash "$helper" cleanup --source-repo "$repo" --workspace "$workspace"); then cleanup_code=0; else cleanup_code=$?; fi
assert_true test "$( [ "$cleanup_code" -eq 0 ] && printf true || printf false )" 'cleanup removes a marked registered worktree'
assert_true test "$( [ ! -e "$workspace" ] && printf true || printf false )" 'cleaned workspace is gone'

unmarked="$temp_root/unmarked"
mkdir -p -- "$unmarked"
if output=$(bash "$helper" cleanup --source-repo "$repo" --workspace "$unmarked"); then rejected_code=0; else rejected_code=$?; fi
assert_true test "$( [ "$rejected_code" -ne 0 ] && printf true || printf false )" 'cleanup rejects an unmarked directory'
assert_true test "$( [ -d "$unmarked" ] && printf true || printf false )" 'rejected directory is preserved'

printf 'all bash execution workspace checks passed (%s tests)\n' "$total"
