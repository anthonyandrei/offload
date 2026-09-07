#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
make_helper="$root/scripts/make-research-workspace.sh"
cleanup_helper="$root/scripts/cleanup-research-workspace.sh"
temp_root=$(mktemp -d "/tmp/offload-research-sh.XXXXXX")
trap 'rm -rf -- "$temp_root"' EXIT
total=0

pass() { total=$((total + 1)); printf 'ok - %s\n' "$1"; }
assert_true() { local value=$2 name=$3; [[ "$value" = true ]] || { printf 'FAIL: %s\n' "$name" >&2; exit 1; }; pass "$name"; }

repo="$temp_root/repo"
mkdir -p -- "$repo/notes"
git -C "$repo" init -q
git -C "$repo" config user.name 'Test User'
git -C "$repo" config user.email 'test@example.com'
printf 'brief source\n' > "$repo/notes/brief.md"
printf 'extra source\n' > "$repo/notes/extra.md"
git -C "$repo" add .
git -C "$repo" commit -q -m initial

workspace="$temp_root/snapshot"
if output=$(bash "$make_helper" --source-repo "$repo" --path notes/brief.md --workspace "$workspace"); then create_code=0; else create_code=$?; fi
assert_true test "$( [ "$create_code" -eq 0 ] && printf true || printf false )" 'research snapshot creation succeeds'
assert_true test "$( [ -f "$workspace/.offload-research-workspace" ] && printf true || printf false )" 'research snapshot has a disposable marker'
assert_true test "$( [ -f "$workspace/repo/notes/brief.md" ] && printf true || printf false )" 'declared source path is copied'
assert_true test "$( [ ! -e "$workspace/repo/notes/extra.md" ] && printf true || printf false )" 'undeclared source path is not copied'

if output=$(bash "$cleanup_helper" --workspace "$workspace" --retain); then retain_code=0; else retain_code=$?; fi
assert_true test "$( [ "$retain_code" -eq 0 ] && printf true || printf false )" 'research retain keeps the snapshot'
assert_true test "$( [ -d "$workspace" ] && printf true || printf false )" 'retained research snapshot remains'
if output=$(bash "$cleanup_helper" --workspace "$workspace"); then remove_code=0; else remove_code=$?; fi
assert_true test "$( [ "$remove_code" -eq 0 ] && printf true || printf false )" 'research cleanup removes a marked snapshot'
assert_true test "$( [ ! -e "$workspace" ] && printf true || printf false )" 'removed research snapshot is gone'

unmarked="$temp_root/unmarked"
mkdir -p -- "$unmarked"
if output=$(bash "$cleanup_helper" --workspace "$unmarked"); then reject_code=0; else reject_code=$?; fi
assert_true test "$( [ "$reject_code" -ne 0 ] && printf true || printf false )" 'research cleanup rejects an unmarked directory'
assert_true test "$( [ -d "$unmarked" ] && printf true || printf false )" 'rejected research directory is preserved'

bad="$temp_root/bad"
if output=$(bash "$make_helper" --source-repo "$repo" --path ../notes/brief.md --workspace "$bad"); then traversal_code=0; else traversal_code=$?; fi
assert_true test "$( [ "$traversal_code" -ne 0 ] && printf true || printf false )" 'research snapshot rejects traversal paths'
assert_true test "$( [ ! -e "$bad" ] && printf true || printf false )" 'failed research snapshot leaves no workspace'

metadata="$temp_root/metadata"
if output=$(bash "$make_helper" --source-repo "$repo" --path .git --workspace "$metadata"); then metadata_code=0; else metadata_code=$?; fi
assert_true test "$( [ "$metadata_code" -ne 0 ] && printf true || printf false )" 'research snapshot rejects Git metadata'
assert_true test "$( [ ! -e "$metadata" ] && printf true || printf false )" 'metadata rejection leaves no workspace'

inside="$repo/snapshot"
if output=$(bash "$make_helper" --source-repo "$repo" --path notes/brief.md --workspace "$inside"); then inside_code=0; else inside_code=$?; fi
assert_true test "$( [ "$inside_code" -ne 0 ] && printf true || printf false )" 'research snapshot rejects a workspace inside the source'
assert_true test "$( [ ! -e "$inside" ] && printf true || printf false )" 'source-bound workspace rejection leaves no workspace'

printf 'all bash research workspace checks passed (%s tests)\n' "$total"
