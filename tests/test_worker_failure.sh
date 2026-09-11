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

launch_counter="$temp_root/launch-counter.txt"
if bash "$fixture" "$launch_counter" launch; then exit_code=0; else exit_code=$?; fi
assert_true test "$( [ "$exit_code" -eq 17 ] && printf true || printf false )" 'failed worker returns its launch failure'
assert_true test "$( [ "$(<"$launch_counter")" -eq 1 ] && printf true || printf false )" 'failed worker is invoked once without provider switch'

quality_counter="$temp_root/quality-counter.txt"
if bash "$fixture" "$quality_counter" quality-escalate; then attempt1_exit=0; else attempt1_exit=$?; fi
assert_true test "$( [ "$attempt1_exit" -eq 20 ] && printf true || printf false )" 'initial worker failure reports quality-gate failure'
assert_true test "$( [ "$(<"$quality_counter")" -eq 1 ] && printf true || printf false )" 'initial worker invoked once'

if bash "$fixture" "$quality_counter" quality-escalate; then attempt2_exit=0; else attempt2_exit=$?; fi
assert_true test "$( [ "$attempt2_exit" -eq 20 ] && printf true || printf false )" 'escalation worker reports quality-gate failure'
assert_true test "$( [ "$(<"$quality_counter")" -eq 2 ] && printf true || printf false )" 'escalation worker invoked on quality failure'

assert_true test "$( printf '%s' "$skill" | grep -Fq 'unfinished assignment' && printf true || printf false )" 'contract returns unfinished work to the orchestrator'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'without automatic provider switching' && printf true || printf false )" 'contract forbids automatic provider switching on infrastructure failure'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'quality-gate failure' && printf '%s' "$skill" | grep -Fq 'exactly one automatic escalation' && printf true || printf false )" 'contract permits one automatic escalation on quality-gate failure'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'smallest credible improvement' && printf true || printf false )" 'escalation chooses smallest credible improvement'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'cross-vendor escalation' && printf true || printf false )" 'generic approval permits cross-vendor escalation'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'constrains escalation to that vendor' && printf true || printf false )" 'named vendor constrains escalation'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'exact model remains pinned' && printf true || printf false )" 'named exact model remains pinned'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'No third automatic attempt is permitted' && printf true || printf false )" 'contract forbids a third automatic attempt'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'Finish the assignment locally when safe' && printf true || printf false )" 'orchestrator finishes locally when safe'
assert_true test "$( printf '%s' "$skill" | grep -Fq 'usable partial result' && printf '%s' "$skill" | grep -Fq 'precise blocker' && printf true || printf false )" 'orchestrator reports partial result and blocker when local completion is unsafe'

printf 'all bash worker failure checks passed (%s tests)\n' "$total"
