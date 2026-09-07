#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
fixture="$root/tests/fixtures/fake-worker-failure.sh"
skill=$(<"$root/SKILL.md")
temp_root=$(mktemp -d "/tmp/offload-failure-sh.XXXXXX")
trap 'rm -rf -- "$temp_root"' EXIT
total=0

pass() { total=$((total + 1)); printf 'ok - %s\n' "$1"; }
assert_true() { local value=$2 name=$3; [[ "$value" = true ]] || { printf 'FAIL: %s\n' "$name" >&2; exit 1; }; pass "$name"; }

counter="$temp_root/counter.txt"
if bash "$fixture" "$counter"; then exit_code=0; else exit_code=$?; fi
assert_true test "$( [ "$exit_code" -eq 17 ] && printf true || printf false )" 'failed worker returns its launch failure'
assert_true test "$( [ "$(cat "$counter")" = 1 ] && printf true || printf false )" 'failed worker is invoked once'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'unfinished assignment' && printf true || printf false )" 'contract returns unfinished work to the orchestrator'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'silent provider switch' && printf true || printf false )" 'contract forbids silent provider switching'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'second automatic attempt' && printf true || printf false )" 'contract forbids an automatic second attempt'

printf 'all bash worker failure checks passed (%s tests)\n' "$total"
