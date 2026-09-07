#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
checker="$root/scripts/check-execution-scope.sh"
temp_root=$(mktemp -d "/tmp/offload-scope-sh.XXXXXX")
trap 'rm -rf -- "$temp_root"' EXIT
total=0

pass() { total=$((total + 1)); printf 'ok - %s\n' "$1"; }
assert_true() { local value=$2 name=$3; [[ "$value" = true ]] || { printf 'FAIL: %s\n' "$name" >&2; exit 1; }; pass "$name"; }

repo="$temp_root/repo"
mkdir -p -- "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name 'Test User'
git -C "$repo" config user.email 'test@example.com'
printf 'owned\n' > "$repo/owned.txt"
printf 'owned with space\n' > "$repo/owned with space.txt"
printf 'unowned\n' > "$repo/unowned.txt"
printf 'frozen\n' > "$repo/frozen.txt"
git -C "$repo" add .
git -C "$repo" commit -q -m initial
baseline=$(git -C "$repo" rev-parse HEAD)

if (cd "$repo" && "$checker" --baseline "$baseline" --owned owned.txt); then clean_code=0; else clean_code=$?; fi
assert_true test "$( [ "$clean_code" -eq 0 ] && printf true || printf false )" 'clean worktree passes'

printf 'owned changed\n' > "$repo/owned.txt"
if (cd "$repo" && "$checker" --baseline "$baseline" --owned owned.txt); then owned_code=0; else owned_code=$?; fi
assert_true test "$( [ "$owned_code" -eq 0 ] && printf true || printf false )" 'owned change passes'

printf 'owned\n' > "$repo/owned.txt"
printf 'owned with space changed\n' > "$repo/owned with space.txt"
if (cd "$repo" && "$checker" --baseline "$baseline" --owned 'owned with space.txt'); then spaced_code=0; else spaced_code=$?; fi
assert_true test "$( [ "$spaced_code" -eq 0 ] && printf true || printf false )" 'owned path with spaces passes'

printf 'unowned changed\n' > "$repo/unowned.txt"
output=''
if output=$(cd "$repo" && "$checker" --baseline "$baseline" --owned owned.txt); then
  unowned_code=0
else
  unowned_code=$?
fi
assert_true test "$( [ "$unowned_code" -ne 0 ] && printf true || printf false )" 'unowned change fails'
assert_true test "$( printf '%s' "$output" | grep -q '^unowned.txt$' && printf true || printf false )" 'unowned path is reported'

printf 'unowned\n' > "$repo/unowned.txt"
printf 'frozen changed\n' > "$repo/frozen.txt"
if output=$(cd "$repo" && "$checker" --baseline "$baseline" --owned owned.txt --frozen frozen.txt); then
  frozen_code=0
else
  frozen_code=$?
fi
assert_true test "$( [ "$frozen_code" -ne 0 ] && printf true || printf false )" 'frozen change fails'
assert_true test "$( printf '%s' "$output" | grep -q '^frozen.txt$' && printf true || printf false )" 'frozen path is reported'

printf 'all bash execution scope checks passed (%s tests)\n' "$total"
