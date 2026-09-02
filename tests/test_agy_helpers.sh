#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-agy-helpers.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fake_bin="$TMP_ROOT/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/agy" <<'FAKE_AGY'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${FAKE_AGY_ARGS:-}" ]; then
  printf '%s\n' "$*" > "$FAKE_AGY_ARGS"
fi
if [ -n "${FAKE_AGY_EXIT:-}" ]; then
  printf '%s\n' 'fake stderr' >&2
  exit "$FAKE_AGY_EXIT"
fi
printf '%s\n' 'fake stderr' >&2
printf '%s\n' '{"status":"success","response":"verbose worker text","structured_output":{"ok":true}}'
FAKE_AGY
chmod +x "$fake_bin/agy"

run_output="$TMP_ROOT/run.json"
run_error="$TMP_ROOT/run.err"
launcher_stdout=$(FAKE_AGY_ARGS="$TMP_ROOT/agy.args" PATH="$fake_bin:$PATH" \
  "$ROOT/scripts/run-agy-json.sh" \
  --output "$run_output" \
  --error "$run_error" \
  -- --prompt 'test prompt' --output-format json)

[ -z "$launcher_stdout" ] || fail 'launcher leaked worker output to stdout'
[ "$(jq -r '.structured_output.ok' "$run_output")" = true ] || fail 'launcher did not preserve JSON output'
[ "$(cat "$run_error")" = 'fake stderr' ] || fail 'launcher did not preserve stderr output'
grep -Fq -- '--output-format json' "$TMP_ROOT/agy.args" || fail 'launcher dropped worker arguments'
! grep -Eq -- '(^| )--output( |$)' "$TMP_ROOT/agy.args" || fail 'launcher passed the forbidden --output flag'
pass 'launcher redirects output and preserves supported worker arguments'

# Argument forwarding with spaces
spaced_args="$TMP_ROOT/spaced.args"
FAKE_AGY_ARGS="$spaced_args" PATH="$fake_bin:$PATH" \
  "$ROOT/scripts/run-agy-json.sh" \
  --output "$TMP_ROOT/spaced.json" \
  --error "$TMP_ROOT/spaced.err" \
  -- --prompt 'test prompt with spaces' --custom-flag 'val with spaces'
grep -Fq -- '--prompt test prompt with spaces' "$spaced_args" || fail 'launcher split argument containing spaces'
grep -Fq -- '--custom-flag val with spaces' "$spaced_args" || fail 'launcher split flag value containing spaces'
pass 'launcher forwards arguments with spaces without splitting'

# Parent directory creation
nested_output="$TMP_ROOT/nested/sub1/run.json"
nested_error="$TMP_ROOT/nested/sub2/run.err"
PATH="$fake_bin:$PATH" \
  "$ROOT/scripts/run-agy-json.sh" \
  --output "$nested_output" \
  --error "$nested_error" \
  -- --prompt 'parent dir test'
[ -f "$nested_output" ] || fail 'launcher did not create parent directory for output file'
[ -f "$nested_error" ] || fail 'launcher did not create parent directory for error file'
pass 'launcher creates parent directories for output and error files'

# Worker exit code propagation
set +e
FAKE_AGY_EXIT=42 PATH="$fake_bin:$PATH" \
  "$ROOT/scripts/run-agy-json.sh" \
  --output "$TMP_ROOT/exit42.json" \
  --error "$TMP_ROOT/exit42.err" \
  -- --prompt 'fail test' 2>/dev/null
exit_code=$?
set -e
[ "$exit_code" -eq 42 ] || fail "launcher did not propagate worker exit code (got $exit_code)"
pass 'launcher propagates worker exit code'

# Forbidden --output rejection (--output and --output=<val>)
if PATH="$fake_bin:$PATH" "$ROOT/scripts/run-agy-json.sh" \
  --output "$TMP_ROOT/rejected.json" \
  --error "$TMP_ROOT/rejected.err" \
  -- --output "$TMP_ROOT/worker-owned.json" 2>/dev/null; then
  fail 'launcher accepted the forbidden --output worker argument'
fi
if PATH="$fake_bin:$PATH" "$ROOT/scripts/run-agy-json.sh" \
  --output "$TMP_ROOT/rejected2.json" \
  --error "$TMP_ROOT/rejected2.err" \
  -- --output=worker-owned.json 2>/dev/null; then
  fail 'launcher accepted the forbidden --output=value worker argument'
fi
pass 'launcher rejects the accidental agy --output and --output=value flags'

# AGY_BIN precedence over PATH
custom_bin="$TMP_ROOT/custom-bin"
mkdir -p "$custom_bin"
cat > "$custom_bin/custom-agy" <<'CUSTOM_AGY'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"status":"success","response":"custom","structured_output":{"from_custom":true}}'
CUSTOM_AGY
chmod +x "$custom_bin/custom-agy"

custom_output="$TMP_ROOT/custom.json"
AGY_BIN="$custom_bin/custom-agy" PATH="$fake_bin:$PATH" \
  "$ROOT/scripts/run-agy-json.sh" \
  --output "$custom_output" \
  --error "$TMP_ROOT/custom.err" \
  -- --prompt 'custom agy'
[ "$(jq -r '.structured_output.from_custom' "$custom_output")" = true ] || fail 'AGY_BIN did not take precedence over PATH'
pass 'AGY_BIN takes precedence over PATH discovery'

# Explicit AGY_BIN invalid failure without fallback
invalid_output="$TMP_ROOT/invalid.json"
set +e
AGY_BIN="$TMP_ROOT/nonexistent-bin" PATH="$fake_bin:$PATH" \
  "$ROOT/scripts/run-agy-json.sh" \
  --output "$invalid_output" \
  --error "$TMP_ROOT/invalid.err" \
  -- --prompt 'test invalid' 2>/dev/null
invalid_exit=$?
set -e
[ "$invalid_exit" -ne 0 ] || fail 'launcher succeeded when explicit AGY_BIN was invalid'
[ ! -e "$invalid_output" ] || fail 'launcher ran fallback worker when explicit AGY_BIN was invalid'
pass 'launcher fails without fallback when explicit AGY_BIN is invalid'

# Structured output extraction
printf '%s\n' '{"response":"long worker prose","structured_output":{"angle":"one","findings":[1]}}' > "$TMP_ROOT/worker-one.json"
printf '%s\n' '{"response":"another long worker prose","structured_output":{"angle":"two","findings":[2]}}' > "$TMP_ROOT/worker-two.json"

# Scalar extraction
scalar_compact="$("$ROOT/scripts/extract-structured-output.sh" "$TMP_ROOT/worker-one.json")"
[ "$(jq -r '.angle' <<< "$scalar_compact")" = 'one' ] || fail 'scalar extractor returned incorrect structured output'
[ "$(jq -r '.findings[0]' <<< "$scalar_compact")" = '1' ] || fail 'scalar extractor returned incorrect nested data'
! grep -Fq 'long worker prose' <<< "$scalar_compact" || fail 'scalar extractor included verbose response prose'
! grep -Fq '"response"' <<< "$scalar_compact" || fail 'scalar extractor included response key'
pass 'scalar extractor emits only compact structured output'

# Array extraction (--array)
compact="$("$ROOT/scripts/extract-structured-output.sh" --array "$TMP_ROOT/worker-one.json" "$TMP_ROOT/worker-two.json")"
[ "$(jq 'length' <<< "$compact")" = 2 ] || fail 'extractor did not return every structured result'
! grep -Fq 'long worker prose' <<< "$compact" || fail 'extractor included verbose response text'
[ "$(jq -r '.[0].angle' <<< "$compact")" = one ] || fail 'extractor did not preserve argument order item 1'
[ "$(jq -r '.[1].angle' <<< "$compact")" = two ] || fail 'extractor did not preserve argument order item 2'
pass 'extractor emits compact structured output array in argument order'

# Structured-output rejection cases
printf '%s\n' '{"response":"missing structure"}' > "$TMP_ROOT/missing.json"
if "$ROOT/scripts/extract-structured-output.sh" "$TMP_ROOT/missing.json" >/dev/null 2>&1; then
  fail 'extractor accepted a scalar result without structured_output'
fi
if "$ROOT/scripts/extract-structured-output.sh" --array "$TMP_ROOT/worker-one.json" "$TMP_ROOT/missing.json" >/dev/null 2>&1; then
  fail 'extractor accepted an array result containing a file without structured_output'
fi

if "$ROOT/scripts/extract-structured-output.sh" "$TMP_ROOT/nonexistent-file.json" >/dev/null 2>&1; then
  fail 'extractor accepted a non-existent input file'
fi

printf '{not valid json\n' > "$TMP_ROOT/malformed.json"
if "$ROOT/scripts/extract-structured-output.sh" "$TMP_ROOT/malformed.json" >/dev/null 2>&1; then
  fail 'extractor accepted malformed JSON'
fi

printf '[{"structured_output":{"ok":true}}]\n' > "$TMP_ROOT/non-object.json"
if "$ROOT/scripts/extract-structured-output.sh" "$TMP_ROOT/non-object.json" >/dev/null 2>&1; then
  fail 'extractor accepted non-object top-level JSON'
fi
pass 'extractor rejects missing, malformed, non-object, and unstructured worker results'

printf '%s\n' 'all agy helper checks passed'
