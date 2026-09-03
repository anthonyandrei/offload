#!/usr/bin/env bash
# tests/test_review_verdict.sh
# Regression coverage for exhaustive reviewer criterion verification.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/scripts/check-review-verdict.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-test-review-verdict.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

ARTIFACT="$TMP_ROOT/review.patch"
CRITERIA="$TMP_ROOT/criteria.json"
printf '%s\n' 'diff --git a/example.txt b/example.txt' '+++ b/example.txt' '+literal evidence line' > "$ARTIFACT"
printf '%s\n' '[{"criterion_id":"C1","text":"first criterion"},{"criterion_id":"C2","text":"second criterion"}]' > "$CRITERIA"

run_case() {
  local name=$1 expected=$2 review=$3 criteria_file=${4:-$CRITERIA}
  local out="$TMP_ROOT/$name.out" err="$TMP_ROOT/$name.err" actual
  set +e
  "$HELPER" --criteria "$criteria_file" --review "$review" --artifact "$ARTIFACT" >"$out" 2>"$err"
  actual=$?
  set -e
  [ "$actual" -eq "$expected" ] || fail "$name expected exit $expected, got $actual: $(cat "$err")"
}

EMPTY="$TMP_ROOT/empty.json"
printf '%s\n' '{"criteria":[]}' > "$EMPTY"
run_case empty 2 "$EMPTY"
pass 'empty reviewer output is rejected'

PARTIAL="$TMP_ROOT/partial.json"
printf '%s\n' '{"criteria":[{"criterion_id":"C1","verdict":"pass","quote":"+literal evidence line"}]}' > "$PARTIAL"
run_case partial 2 "$PARTIAL"
pass 'partial reviewer coverage is rejected'

MALFORMED="$TMP_ROOT/malformed.json"
printf '%s\n' '{"criteria":[{"criterion_id":"C1","verdict":"pass"},{"criterion_id":"C2","verdict":"pass","quote":"+literal evidence line"}]}' > "$MALFORMED"
run_case malformed 2 "$MALFORMED"
pass 'malformed reviewer entries are rejected'

DUPLICATE="$TMP_ROOT/duplicate.json"
printf '%s\n' '{"criteria":[{"criterion_id":"C1","verdict":"pass","quote":"+literal evidence line"},{"criterion_id":"C1","verdict":"pass","quote":"+literal evidence line"},{"criterion_id":"C2","verdict":"pass","quote":"+literal evidence line"}]}' > "$DUPLICATE"
run_case duplicate 2 "$DUPLICATE"
pass 'duplicate criterion IDs are rejected'

UNKNOWN="$TMP_ROOT/unknown.json"
printf '%s\n' '{"criteria":[{"criterion_id":"C1","verdict":"pass","quote":"+literal evidence line"},{"criterion_id":"C2","verdict":"pass","quote":"+literal evidence line"},{"criterion_id":"C3","verdict":"pass","quote":"+literal evidence line"}]}' > "$UNKNOWN"
run_case unknown 2 "$UNKNOWN"
pass 'unknown criterion IDs are rejected'

FAILED="$TMP_ROOT/failed.json"
printf '%s\n' '{"criteria":[{"criterion_id":"C1","verdict":"fail","quote":""},{"criterion_id":"C2","verdict":"pass","quote":"+literal evidence line"}]}' > "$FAILED"
run_case failed 1 "$FAILED"
pass 'complete failed verdicts block automated acceptance'

HEDGED="$TMP_ROOT/hedged.json"
printf '%s\n' '{"criteria":[{"criterion_id":"C1","verdict":"hedge","quote":""},{"criterion_id":"C2","verdict":"pass","quote":"+literal evidence line"}]}' > "$HEDGED"
run_case hedged 1 "$HEDGED"
pass 'complete hedged verdicts block automated acceptance'

FORGED="$TMP_ROOT/forged.json"
printf '%s\n' '{"criteria":[{"criterion_id":"C1","verdict":"pass","quote":"+forged evidence line"},{"criterion_id":"C2","verdict":"pass","quote":"+literal evidence line"}]}' > "$FORGED"
run_case forged 2 "$FORGED"
pass 'forged evidence quotes are rejected'

COMPLETE="$TMP_ROOT/complete.json"
printf '%s\n' '{"structured_output":{"criteria":[{"criterion_id":"C1","verdict":"pass","quote":"+literal evidence line"},{"criterion_id":"C2","verdict":"pass","quote":"+++ b/example.txt"}]}}' > "$COMPLETE"
run_case complete 0 "$COMPLETE"
pass 'complete all-pass reviewer output with artifact evidence is accepted'

SINGLE_CRITERIA="$TMP_ROOT/single-criteria.json"
printf '%s\n' '[{"criterion_id":"C1","text":"only criterion"}]' > "$SINGLE_CRITERIA"
SINGLE_REVIEW="$TMP_ROOT/single-review.json"
printf '%s\n' '{"criteria":[{"criterion_id":"C1","verdict":"pass","quote":"+literal evidence line"}]}' > "$SINGLE_REVIEW"
run_case single 0 "$SINGLE_REVIEW" "$SINGLE_CRITERIA"
pass 'single-criterion arrays are preserved'

printf 'all review verdict shell tests passed\n'
