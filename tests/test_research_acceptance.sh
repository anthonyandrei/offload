#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
skill=$(<"$root/SKILL.md")
total=0

pass() { total=$((total + 1)); printf 'ok - %s\n' "$1"; }
assert_contains() { [[ "$skill" == *"$1"* ]] || { printf 'FAIL: %s\n' "$2" >&2; exit 1; }; pass "$2"; }
assert_absent() { [[ "$skill" != *"$1"* ]] || { printf 'FAIL: %s\n' "$2" >&2; exit 1; }; pass "$2"; }

assert_contains 'Reject broken citations' 'broken citations are rejected'
assert_contains 'claims not supported by their cited sources' 'unsupported claims are rejected'
assert_contains 'claims they support' 'supported claims are accepted only after review'
assert_contains 'Mark inference, uncertainty, disagreement, missing evidence, and stale evidence plainly' 'inference, uncertainty, disagreement, and stale evidence remain visible'
assert_contains 'Do not require a universal result envelope' 'research acceptance needs no universal result envelope'
assert_absent 'routing-outcomes' 'research acceptance has no routing history schema'
assert_absent 'provenance' 'research acceptance has no provenance schema'
assert_absent 'schema_version' 'research acceptance has no universal schema'
assert_absent 'check-citation-audit' 'research acceptance has no deleted citation helper'

printf 'all bash research acceptance checks passed (%s tests)\n' "$total"
