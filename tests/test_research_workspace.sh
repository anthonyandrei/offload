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

if output=$(OFFLOAD_WORKER_CONTEXT=1 bash "$make_helper" --source-repo "$repo" --path notes/brief.md --workspace "$temp_root/worker-snapshot"); then worker_make_code=0; else worker_make_code=$?; fi
assert_true test "$( [ "$worker_make_code" -ne 0 ] && printf true || printf false )" 'worker context cannot create a research snapshot'

workspace="$temp_root/snapshot"
if output=$(bash "$make_helper" --source-repo "$repo" --path notes/brief.md --workspace "$workspace"); then create_code=0; else create_code=$?; fi
assert_true test "$( [ "$create_code" -eq 0 ] && printf true || printf false )" 'research snapshot creation succeeds'
assert_true test "$( [ -f "$workspace/.offload-research-workspace" ] && printf true || printf false )" 'research snapshot has a disposable marker'
assert_true test "$( [ -f "$workspace/repo/notes/brief.md" ] && printf true || printf false )" 'declared source path is copied'
assert_true test "$( [ ! -e "$workspace/repo/notes/extra.md" ] && printf true || printf false )" 'undeclared source path is not copied'

if output=$(bash "$cleanup_helper" --workspace "$workspace" --retain); then retain_code=0; else retain_code=$?; fi
assert_true test "$( [ "$retain_code" -eq 0 ] && printf true || printf false )" 'research retain keeps the snapshot'
assert_true test "$( [ -d "$workspace" ] && printf true || printf false )" 'retained research snapshot remains'
if output=$(OFFLOAD_WORKER_CONTEXT=1 bash "$cleanup_helper" --workspace "$workspace"); then worker_cleanup_code=0; else worker_cleanup_code=$?; fi
assert_true test "$( [ "$worker_cleanup_code" -ne 0 ] && printf true || printf false )" 'worker context cannot remove a research snapshot'
if output=$(bash "$cleanup_helper" --workspace "$workspace"); then remove_code=0; else remove_code=$?; fi
assert_true test "$( [ "$remove_code" -eq 0 ] && printf true || printf false )" 'research cleanup removes a marked snapshot'
assert_true test "$( [ ! -e "$workspace" ] && printf true || printf false )" 'removed research snapshot is gone'

leftover="$temp_root/snapshot-leftover"
if output=$(bash "$make_helper" --source-repo "$repo" --path notes/brief.md --workspace "$leftover"); then leftover_create_code=0; else leftover_create_code=$?; fi
assert_true test "$( [ "$leftover_create_code" -eq 0 ] && printf true || printf false )" 'research cleanup verification fixture is created'
fake_bin="$temp_root/fake-bin"
mkdir -p -- "$fake_bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fake_bin/rmdir"
chmod +x "$fake_bin/rmdir"
cleanup_error="$temp_root/research-cleanup-error"
if output=$(PATH="$fake_bin:$PATH" bash "$cleanup_helper" --workspace "$leftover" 2>"$cleanup_error"); then leftover_cleanup_code=0; else leftover_cleanup_code=$?; fi
assert_true test "$( [ "$leftover_cleanup_code" -ne 0 ] && printf true || printf false )" 'research cleanup fails when removal leaves the workspace'
assert_true test "$( grep -Fq -- "$leftover" "$cleanup_error" && printf true || printf false )" 'research cleanup failure names the leftover workspace'
assert_true test "$( [ -e "$leftover" ] && printf true || printf false )" 'failed research cleanup preserves the leftover workspace'

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

marked_inside="$repo/marked-snapshot"
mkdir -p -- "$marked_inside"
printf 'offload-research-workspace-v2\n' > "$marked_inside/.offload-research-workspace"
if output=$(bash "$cleanup_helper" --workspace "$marked_inside"); then marked_inside_code=0; else marked_inside_code=$?; fi
assert_true test "$( [ "$marked_inside_code" -ne 0 ] && printf true || printf false )" 'research cleanup rejects a marked directory inside a Git repository'
assert_true test "$( [ -d "$marked_inside" ] && printf true || printf false )" 'Git-contained research directory is preserved'

copy_failure="$temp_root/copy-failure"
copy_fake_bin="$temp_root/copy-fake-bin"
mkdir -p -- "$copy_fake_bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$copy_fake_bin/cp"
chmod +x "$copy_fake_bin/cp"
if output=$(PATH="$copy_fake_bin:$PATH" bash "$make_helper" --source-repo "$repo" --path notes/brief.md --workspace "$copy_failure"); then copy_failure_code=0; else copy_failure_code=$?; fi
assert_true test "$( [ "$copy_failure_code" -ne 0 ] && printf true || printf false )" 'research snapshot reports copy failure'
assert_true test "$( [ ! -e "$copy_failure" ] && printf true || printf false )" 'failed research snapshot creation cleans its workspace'

printf 'all bash research workspace checks passed (%s tests)\n' "$total"
