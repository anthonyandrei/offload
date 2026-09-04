#!/usr/bin/env bash
# Acceptance tests for vendor-neutral catalog selection in run-agy-json.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAUNCHER="$ROOT/scripts/run-agy-json.sh"
ADAPTER="$ROOT/tests/fixtures/fake-worker-adapter.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

[ -x "$LAUNCHER" ] || fail "launcher is not executable"
[ -x "$ADAPTER" ] || fail "fake adapter is not executable"
bash -n "$LAUNCHER" || fail "launcher does not parse"
bash -n "$ADAPTER" || fail "fake adapter does not parse"
jq empty "$ROOT/model-policy.json" >/dev/null || fail "policy is not valid JSON"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-model-routing.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

catalog_one="$TMP_ROOT/catalog-one.json"
catalog_two="$TMP_ROOT/catalog-two.json"
catalog_three="$TMP_ROOT/catalog-three.json"
selection="$TMP_ROOT/selection.json"
capture="$TMP_ROOT/capture.json"
cat >"$catalog_one" <<'JSON'
{
  "protocol_version": 1, "adapter": "fake", "adapter_revision": "fake-1",
  "vendor": "vendor-a", "catalog_revision": "catalog-1",
  "models": [
    {"id":"unavailable","family_hint":"fast","available":false,"supported_efforts":["low"],"capabilities":[],"scores":{"fast":0}},
    {"id":"needs-deep","family_hint":"deep","available":true,"quota_available":true,"supported_efforts":["high"],"capabilities":["deep"],"scores":{"balanced":2}},
    {"id":"selected-model","family_hint":"flash","available":true,"quota_available":true,"supported_efforts":["high"],"capabilities":[],"scores":{"balanced":1}},
    {"id":"wrong-effort","family_hint":"slow","available":true,"quota_available":true,"supported_efforts":["low"],"capabilities":[],"scores":{"balanced":0}}
  ]
}
JSON
cat >"$catalog_three" <<'JSON'
{
  "protocol_version": 1, "adapter": "fake", "adapter_revision": "fake-1",
  "vendor": "vendor-a", "catalog_revision": "catalog-3",
  "models": [
    {"id":"model-without-scores","family_hint":"unknown","available":true,"quota_available":true,"supported_efforts":["high"],"capabilities":[]}
  ]
}
JSON
cat >"$catalog_two" <<'JSON'
{
  "protocol_version": 1, "adapter": "fake", "adapter_revision": "fake-1",
  "vendor": "vendor-a", "catalog_revision": "catalog-2",
  "models": [
    {"id":"new-top-model","family_hint":"new-family","available":true,"quota_available":true,"supported_efforts":["high"],"capabilities":[],"scores":{"balanced":0}},
    {"id":"selected-model","family_hint":"flash","available":true,"quota_available":true,"supported_efforts":["high"],"capabilities":[],"scores":{"balanced":5}}
  ]
}
JSON

run_launcher() {
  local catalog="$1"; shift
  local out="$TMP_ROOT/output.json" err="$TMP_ROOT/error.log"
  local preserve_selection=false
  for arg in "$@"; do
    case "$arg" in --pin|--pin=*) preserve_selection=true ;; esac
  done
  rm -f "$out" "$err" "$capture"
  $preserve_selection || rm -f "$selection"
  set +e
  FAKE_ADAPTER_CATALOG="$catalog" FAKE_ADAPTER_CAPTURE="$capture" OFFLOAD_ADAPTER_BIN="$ADAPTER" \
    "$LAUNCHER" --role implementer --selection-output "$selection" --output "$out" --error "$err" "$@"
  RUN_EXIT=$?
  set -e
  RUN_OUT="$out"; RUN_ERR="$err"
}

run_launcher "$catalog_one" -- --prompt "prompt with spaces" --output-format json
[ "$RUN_EXIT" -eq 0 ] || fail "normal catalog selection failed"
[ "$(jq -r '.model_id' "$selection")" = selected-model ] || fail "deterministic selection chose the wrong model"
[ "$(jq -r '.family_hint' "$selection")" = flash ] || fail "family hint was not recorded"
[ "$(jq -r '.effort' "$selection")" = high ] || fail "effort was not recorded separately"
[ "$(jq -r '.selection_reason' "$selection")" != null ] || fail "selection reason was not recorded"
[ "$(jq -r '.selection.model_id' "$capture")" = selected-model ] || fail "adapter did not receive selected model"
[ "$(jq -r '.worker_args[1]' "$capture")" = 'prompt with spaces' ] || fail "worker argument boundaries were not preserved"
pass "filters availability, effort, and capability constraints"

run_launcher "$catalog_two" --pin "$selection" -- --prompt retry
[ "$RUN_EXIT" -eq 0 ] || fail "pinned retry failed after catalog revision changed"
[ "$(jq -r '.model_id' "$selection")" = selected-model ] || fail "pinned retry silently changed model"
[ "$(jq -r '.catalog_revision' "$selection")" = catalog-2 ] || fail "pinned retry did not record current catalog revision"
pass "pins selected model across catalog revisions"

run_launcher "$catalog_three" -- --prompt no-score
[ "$RUN_EXIT" -eq 0 ] || fail "catalog model without a score map failed"
[ "$(jq -r '.model_id' "$selection")" = model-without-scores ] || fail "catalog model without a score map was not selected"
pass "missing preference scores use the deterministic fallback"

run_launcher "$catalog_one" -- --prompt capability-baseline
[ "$RUN_EXIT" -eq 0 ] || fail "capability pin baseline selection failed"
set +e
FAKE_ADAPTER_CATALOG="$catalog_one" OFFLOAD_ADAPTER_BIN="$ADAPTER" \
  "$LAUNCHER" --role implementer --require-capability deep --pin "$selection" --output "$TMP_ROOT/capability.out" --error "$TMP_ROOT/capability.err" -- --prompt retry >/dev/null 2>&1
pin_capability_exit=$?
set -e
[ "$pin_capability_exit" -eq 3 ] || fail "pinned model bypassed required capabilities"
pass "pinned selections remain subject to capability constraints"

set +e
FAKE_ADAPTER_CATALOG="$catalog_two" OFFLOAD_ADAPTER_BIN="$ADAPTER" \
  "$LAUNCHER" --role implementer --pin "$TMP_ROOT/missing-pin.json" --output "$TMP_ROOT/missing.out" --error "$TMP_ROOT/missing.err" -- --prompt retry >/dev/null 2>&1
missing_pin_exit=$?
set -e
[ "$missing_pin_exit" -eq 3 ] || fail "missing pin did not require explicit fallback or handoff"
pass "missing pin is an explicit handoff condition"

set +e
FAKE_ADAPTER_CATALOG="$catalog_one" OFFLOAD_ADAPTER_BIN="$ADAPTER" \
  "$LAUNCHER" --role implementer --output "$TMP_ROOT/model.out" --error "$TMP_ROOT/model.err" -- --model forbidden >/dev/null 2>&1
caller_model_exit=$?
set -e
[ "$caller_model_exit" -eq 2 ] || fail "caller-supplied model was not rejected"
pass "caller cannot override model selection"

printf '%s\n' 'all adapter model selection checks passed'
