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
printf '%s\n' "$*" > "$FAKE_AGY_ARGS"
printf '%s\n' 'fake stderr' >&2
printf '%s\n' '{"status":"success","response":"verbose worker text","structured_output":{"ok":true}}'
FAKE_AGY
chmod +x "$fake_bin/agy"

run_output="$TMP_ROOT/run.json"
run_error="$TMP_ROOT/run.err"
FAKE_AGY_ARGS="$TMP_ROOT/agy.args" PATH="$fake_bin:$PATH" \
  "$ROOT/scripts/run-agy-json.sh" \
  --output "$run_output" \
  --error "$run_error" \
  -- --prompt 'test prompt' --output-format json

[ "$(jq -r '.structured_output.ok' "$run_output")" = true ] || fail 'launcher did not preserve JSON output'
[ "$(cat "$run_error")" = 'fake stderr' ] || fail 'launcher did not preserve stderr output'
grep -Fq -- '--output-format json' "$TMP_ROOT/agy.args" || fail 'launcher dropped worker arguments'
! grep -Eq -- '(^| )--output( |$)' "$TMP_ROOT/agy.args" || fail 'launcher passed the forbidden --output flag'
pass 'launcher redirects output and preserves supported worker arguments'

if PATH="$fake_bin:$PATH" "$ROOT/scripts/run-agy-json.sh" \
  --output "$TMP_ROOT/rejected.json" \
  --error "$TMP_ROOT/rejected.err" \
  -- --output "$TMP_ROOT/worker-owned.json" 2>/dev/null; then
  fail 'launcher accepted the forbidden --output worker argument'
fi
pass 'launcher rejects the accidental agy --output flag'

printf '%s\n' '{"response":"long worker prose","structured_output":{"angle":"one","findings":[1]}}' > "$TMP_ROOT/worker-one.json"
printf '%s\n' '{"response":"another long worker prose","structured_output":{"angle":"two","findings":[2]}}' > "$TMP_ROOT/worker-two.json"
compact="$("$ROOT/scripts/extract-structured-output.sh" --array "$TMP_ROOT/worker-one.json" "$TMP_ROOT/worker-two.json")"
[ "$(jq 'length' <<< "$compact")" = 2 ] || fail 'extractor did not return every structured result'
! grep -Fq 'long worker prose' <<< "$compact" || fail 'extractor included verbose response text'
[ "$(jq -r '.[1].angle' <<< "$compact")" = two ] || fail 'extractor changed structured result data'
pass 'extractor emits only compact structured output'

printf '%s\n' '{"response":"missing structure"}' > "$TMP_ROOT/missing.json"
if "$ROOT/scripts/extract-structured-output.sh" --array "$TMP_ROOT/missing.json" >/dev/null 2>&1; then
  fail 'extractor accepted a result without structured_output'
fi
pass 'extractor rejects unstructured worker results'

printf '%s\n' 'all agy helper checks passed'
