#!/usr/bin/env bash
# Acceptance tests for AGY discovery, preflight normalization, and diagnostics.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/scripts/agy-adapter.sh"
SELECTOR="$ROOT/scripts/select-compatible-worker.sh"
FIXTURE="$ROOT/tests/fixtures/agy-preflight/scenarios.json"
FAKE_FIXTURE="$ROOT/tests/fixtures/agy-preflight/fake-agy.sh"
POLICY="$ROOT/model-policy.json"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

[ -x "$ADAPTER" ] || fail 'AGY adapter is not executable'
[ -x "$SELECTOR" ] || fail 'Bash selector is not executable'
bash -n "$ADAPTER" || fail 'AGY adapter does not parse'
bash -n "$SELECTOR" || fail 'Bash selector does not parse'
jq empty "$FIXTURE" >/dev/null || fail 'fixture is not valid JSON'
jq empty "$POLICY" >/dev/null || fail 'policy is not valid JSON'

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-agy-preflight.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fake_agy="$TMP_ROOT/fake-agy.sh"
cp "$FAKE_FIXTURE" "$fake_agy"
chmod +x "$fake_agy"

request="$TMP_ROOT/request.json"
jq -n '{protocol_version:2,role:"researcher",preference:"balanced",effort:"high",required_capabilities:[],policy_revision:"policy-1",route:"default"}' >"$request"

catalog="$TMP_ROOT/adapter-catalog.json"
adapter_error="$TMP_ROOT/adapter-error.log"
adapter_calls="$TMP_ROOT/adapter-calls.log"
set +e
AGY_BIN="$fake_agy" AGY_PREFLIGHT_FIXTURE="$FIXTURE" AGY_PREFLIGHT_SCENARIO='unsupported-usage' AGY_PREFLIGHT_CALL_LOG="$adapter_calls" \
  "$ADAPTER" --operation catalog --request "$request" >"$catalog" 2>"$adapter_error"
adapter_exit=$?
set -e
[ "$adapter_exit" -eq 0 ] || fail "model-list fixture failed with exit code $adapter_exit"
jq -e '
  .protocol_version == 2 and (.models | length) > 0 and
  ([.models[] | .preflight.access.state == "unknown"] | all) and
  ([.models[] | .preflight.entitlement.state == "unknown"] | all) and
  ([.models[] | .preflight.usage.state == "unknown"] | all) and
  ([.models[] | (.preflight.usage.reason | contains("failed with exit code 2"))] | all) and
  ([.models[] | (has("available") or has("quota_available"))] | any | not)
' "$catalog" >/dev/null || fail 'unsupported AGY discovery was normalized incorrectly'
grep -F -q -- 'models' "$adapter_calls" || fail 'catalog discovery did not call the model-list interface'
grep -F -q -- '/usage' "$adapter_calls" || fail 'catalog discovery did not call the bounded usage interface'
if grep -Eq -- '(^| )--model( |$)' "$adapter_calls"; then fail 'catalog discovery launched a worker'; fi
if grep -F -q -- 'prompt' "$adapter_calls"; then fail 'catalog discovery sent a billable prompt'; fi
pass 'model-list fixture preserves unknown preflight state and avoids launch'

timestamp_catalog="$TMP_ROOT/timestamp-catalog.json"
timestamp_error="$TMP_ROOT/timestamp-error.log"
timestamp_calls="$TMP_ROOT/timestamp-calls.log"
set +e
AGY_BIN="$fake_agy" AGY_PREFLIGHT_FIXTURE="$FIXTURE" AGY_PREFLIGHT_SCENARIO='verified' AGY_PREFLIGHT_CALL_LOG="$timestamp_calls" \
  "$ADAPTER" --operation catalog --request "$request" >"$timestamp_catalog" 2>"$timestamp_error"
timestamp_exit=$?
set -e
[ "$timestamp_exit" -eq 0 ] || fail 'valid usage fixture did not return a catalog'
jq -e '[.models[] | (.preflight.usage.observed_at | type == "string" and length > 0)] | all' "$timestamp_catalog" >/dev/null || fail 'usage discovery discarded the observation timestamp'
pass 'usage discovery preserves the observation timestamp'

model_timeout_output="$TMP_ROOT/model-timeout-catalog.json"
model_timeout_error="$TMP_ROOT/model-timeout-error.log"
model_timeout_calls="$TMP_ROOT/model-timeout-calls.log"
set +e
AGY_BIN="$fake_agy" AGY_PREFLIGHT_FIXTURE="$FIXTURE" AGY_PREFLIGHT_SCENARIO='timed-out-models' AGY_PREFLIGHT_CALL_LOG="$model_timeout_calls" \
  "$ADAPTER" --operation catalog --request "$request" >"$model_timeout_output" 2>"$model_timeout_error"
model_timeout_exit=$?
set -e
[ "$model_timeout_exit" -eq 127 ] || fail 'model discovery timeout did not fail closed'
grep -F -q -- 'catalog discovery timed out' "$model_timeout_error" || fail 'model discovery timeout was not diagnosed precisely'
if grep -F -q -- '/usage' "$model_timeout_calls"; then fail 'model discovery timeout continued to usage probing'; fi
pass 'model discovery timeout is bounded and fails closed'

for provider_exit_code in 124 137; do
  provider_failure_output="$TMP_ROOT/models-exit-$provider_exit_code-catalog.json"
  provider_failure_error="$TMP_ROOT/models-exit-$provider_exit_code-error.log"
  provider_failure_calls="$TMP_ROOT/models-exit-$provider_exit_code-calls.log"
  set +e
  AGY_BIN="$fake_agy" AGY_PREFLIGHT_FIXTURE="$FIXTURE" AGY_PREFLIGHT_SCENARIO="models-exit-$provider_exit_code" AGY_PREFLIGHT_CALL_LOG="$provider_failure_calls" \
    "$ADAPTER" --operation catalog --request "$request" >"$provider_failure_output" 2>"$provider_failure_error"
  provider_failure_exit=$?
  set -e
  [ "$provider_failure_exit" -eq 127 ] || fail "provider model failure $provider_exit_code did not fail closed"
  grep -F -q -- "failed with exit code $provider_exit_code" "$provider_failure_error" || fail "provider model failure $provider_exit_code lost its exit diagnostic"
  if grep -F -q -- 'discovery timed out' "$provider_failure_error"; then fail "provider model failure $provider_exit_code was mislabeled as a timeout"; fi
done
pass 'provider model exit codes 124 and 137 remain distinct from timeouts'

for provider_exit_code in 124 137; do
  usage_failure_output="$TMP_ROOT/usage-exit-$provider_exit_code-catalog.json"
  usage_failure_error="$TMP_ROOT/usage-exit-$provider_exit_code-error.log"
  usage_failure_calls="$TMP_ROOT/usage-exit-$provider_exit_code-calls.log"
  set +e
  AGY_BIN="$fake_agy" AGY_PREFLIGHT_FIXTURE="$FIXTURE" AGY_PREFLIGHT_SCENARIO="usage-exit-$provider_exit_code" AGY_PREFLIGHT_CALL_LOG="$usage_failure_calls" \
    "$ADAPTER" --operation catalog --request "$request" >"$usage_failure_output" 2>"$usage_failure_error"
  usage_failure_exit=$?
  set -e
  [ "$usage_failure_exit" -eq 0 ] || fail "provider usage failure $provider_exit_code did not return a catalog"
  jq -e --arg code "$provider_exit_code" '[.models[].preflight.usage.reason | contains("failed with exit code " + $code)] | all' "$usage_failure_output" >/dev/null || fail "provider usage failure $provider_exit_code lost its exit diagnostic"
  if jq -e '[.models[].preflight.usage.reason | contains("timed out")] | any' "$usage_failure_output" >/dev/null; then fail "provider usage failure $provider_exit_code was mislabeled as a timeout"; fi
done
pass 'provider usage exit codes 124 and 137 remain distinct from timeouts'

redaction_output="$TMP_ROOT/redaction-catalog.json"
redaction_error="$TMP_ROOT/redaction-error.log"
redaction_calls="$TMP_ROOT/redaction-calls.log"
set +e
AGY_BIN="$fake_agy" AGY_PREFLIGHT_FIXTURE="$FIXTURE" AGY_PREFLIGHT_SCENARIO='redaction-unsupported-usage' AGY_PREFLIGHT_CALL_LOG="$redaction_calls" \
  "$ADAPTER" --operation catalog --request "$request" >"$redaction_output" 2>"$redaction_error"
redaction_exit=$?
set -e
[ "$redaction_exit" -eq 0 ] || fail 'redaction fixture did not complete'
redaction_sentinel=$(jq -r '.redaction_sentinel' "$FIXTURE")
if grep -F -q -- "$redaction_sentinel" "$redaction_output" "$redaction_error"; then fail 'adapter leaked raw provider stderr secrets'; fi
pass 'adapter suppresses raw provider stderr secrets'

make_catalog() {
  # Selector cases start at the protocol-2 boundary. Raw AGY normalization is
  # exercised above; the live CLI cannot produce verified access or entitlement.
  local scenario="$1"
  local destination="$2"
  local access_state='verified'
  local account_ref='fixture-account'
  local entitlement_state='active'
  local billing_route='included'
  local usage_state='known'
  local usage_reason='fixture usage is known and fresh'
  local observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local scopes='[{"scope_id":"fixture-window","remaining_units":20,"reserved_units":0}]'
  local cancellation_pending=false

  case "$scenario" in
    unauthenticated) access_state='unauthenticated'; account_ref='' ;;
    missing-access) access_state='unknown'; account_ref='' ;;
    wrong-account) access_state='denied'; account_ref='' ;;
    expired) entitlement_state='expired' ;;
    paid-fallback) billing_route='paid-fallback' ;;
    wrong-billing) billing_route='denied' ;;
    exhausted) usage_state='exhausted'; usage_reason='fixture provider reports exhausted capacity'; scopes='[{"scope_id":"fixture-window","remaining_units":0,"reserved_units":0}]' ;;
    insufficient-capacity|insufficient-capacity-explicit-provider) usage_state='known'; usage_reason='fixture provider reports insufficient capacity'; scopes='[{"scope_id":"fixture-window","remaining_units":2,"reserved_units":0}]' ;;
    exhausted-explicit-provider) usage_state='exhausted'; usage_reason='fixture provider reports exhausted capacity'; scopes='[{"scope_id":"fixture-window","remaining_units":0,"reserved_units":0}]' ;;
    mixed-case-states) access_state='VeRiFiEd'; entitlement_state='AcTiVe'; billing_route='InClUdEd'; usage_state='KNOWN' ;;
    continuing) entitlement_state='continuing' ;;
    cancellation-pending) entitlement_state='continuing'; cancellation_pending=true ;;
    missing-usage) usage_state='unknown'; usage_reason='fixture omitted usage response'; observed_at=''; scopes='[]' ;;
    malformed-usage) usage_state='malformed'; usage_reason='fixture usage response was malformed'; observed_at=''; scopes='[]' ;;
    stale-usage) usage_state='stale'; usage_reason='fixture usage observation is stale'; observed_at='2000-01-01T00:00:00Z' ;;
    unsupported-usage) usage_state='unknown'; usage_reason='fixture usage interface is unsupported'; observed_at=''; scopes='[]' ;;
    timed-out-usage) usage_state='timed-out'; usage_reason='fixture usage probe timed out'; observed_at=''; scopes='[]' ;;
    unknown-usage-explicit-provider) usage_state='unknown'; usage_reason='fixture omitted usage response'; observed_at=''; scopes='[]' ;;
  esac

  jq -n \
    --arg scenario "$scenario" \
    --arg access_state "$access_state" --arg account_ref "$account_ref" \
    --arg entitlement_state "$entitlement_state" --arg billing_route "$billing_route" \
    --arg usage_state "$usage_state" --arg usage_reason "$usage_reason" \
    --arg observed_at "$observed_at" --argjson scopes "$scopes" \
    --argjson cancellation_pending "$cancellation_pending" \
    '{
      protocol_version:2,
      adapter:"agy",
      adapter_revision:"agy-fixture-1",
      vendor:"agy",
      catalog_revision:("fixture-" + $scenario),
      models:[{
        id:("fixture-" + $scenario),
        provider:"agy",
        family_hint:"flash",
        supported_efforts:["high"],
        capabilities:[],
        scores:{fast:1,balanced:1,deep:1},
        preflight:{
          access:{state:$access_state,reason:("fixture access state " + $access_state),account_ref:$account_ref},
          entitlement:{state:$entitlement_state,reason:("fixture entitlement state " + $entitlement_state),billing_route:$billing_route,cancellation_pending:$cancellation_pending},
          usage:{state:$usage_state,reason:$usage_reason,source:"agy-fixture",observed_at:$observed_at,scopes:$scopes}
        }
      }]
    }' >"$destination"
}

run_selector() {
  local catalog_path="$1"
  local output_path="$2"
  local error_path="$3"
  shift 3
  set +e
  "$SELECTOR" --catalog "$catalog_path" --policy "$POLICY" --request "$request" --output "$output_path" "$@" >"$output_path.stdout" 2>"$error_path"
  selector_exit=$?
  set -e
}

for scenario in verified unauthenticated missing-access wrong-account expired paid-fallback wrong-billing exhausted insufficient-capacity exhausted-explicit-provider insufficient-capacity-explicit-provider mixed-case-states continuing cancellation-pending missing-usage malformed-usage stale-usage unsupported-usage timed-out-usage unknown-usage-explicit-provider; do
  scenario_catalog="$TMP_ROOT/$scenario-catalog.json"
  scenario_output="$TMP_ROOT/$scenario-selection.json"
  scenario_error="$TMP_ROOT/$scenario-error.log"
  make_catalog "$scenario" "$scenario_catalog"
  selector_options=()
  explicit=false
  if [[ "$scenario" == *-explicit-provider ]]; then
    selector_options+=(--provider agy --allow-unknown-usage)
    explicit=true
  fi
  run_selector "$scenario_catalog" "$scenario_output" "$scenario_error" "${selector_options[@]}"

  case "$scenario" in
    verified|mixed-case-states|continuing|cancellation-pending)
      [ "$selector_exit" -eq 0 ] || fail "$scenario was not eligible"
      jq -e '.eligibility == "eligible" and .provider == "agy" and .usage_uncertain == false' "$scenario_output" >/dev/null || fail "$scenario selection record was incorrect"
      jq -e '.preflight.access.account_ref == "[redacted]"' "$scenario_output" >/dev/null || fail "$scenario selection did not redact the account reference"
      if grep -F -q -- 'fixture-account' "$scenario_output.stdout"; then fail "$scenario selection leaked the raw account reference"; fi
      if [ "$scenario" = cancellation-pending ]; then
        jq -e '.preflight.entitlement.cancellation_pending == true' "$scenario_output" >/dev/null || fail 'cancellation-pending was not traceable while eligible'
      fi
      pass "$scenario remains eligible with known usage"
      ;;
    unknown-usage-explicit-provider)
      [ "$selector_exit" -eq 0 ] || fail 'explicit provider did not allow unknown usage'
      jq -e '.eligibility == "eligible" and .usage_uncertain == true and (.preflight_reasons | join(" ") | contains("usage"))' "$scenario_output" >/dev/null || fail 'explicit unknown usage was not traceable'
      pass 'explicit provider records uncertain usage without claiming capacity'
      ;;
    *)
      case "$scenario" in
        exhausted-explicit-provider|insufficient-capacity-explicit-provider) expected_exit=3 ;;
        *) expected_exit=4 ;;
      esac
      [ "$selector_exit" -eq "$expected_exit" ] || fail "$scenario was not rejected with the expected ineligible exit code"
      case "$scenario" in
        unauthenticated) expected='provider-confirmed access failure' ;;
        missing-access) expected='access verification unavailable or unsupported' ;;
        wrong-account) expected='provider-confirmed access failure' ;;
        expired) expected='provider-confirmed entitlement expired' ;;
        paid-fallback) expected='provider-confirmed paid fallback' ;;
        wrong-billing) expected='provider-confirmed billing failure' ;;
        exhausted|exhausted-explicit-provider) expected='provider-confirmed usage exhausted' ;;
        insufficient-capacity|insufficient-capacity-explicit-provider) expected='provider-confirmed capacity insufficient' ;;
        malformed-usage) expected='usage observation is malformed' ;;
        stale-usage) expected='usage observation is stale' ;;
        timed-out-usage) expected='usage probe timed out' ;;
        *) expected='usage verification unavailable or unsupported' ;;
      esac
      grep -F -q -- "$expected" "$scenario_error" || fail "$scenario did not preserve the expected diagnostic"
      if [[ "$scenario" != exhausted && "$scenario" != exhausted-explicit-provider ]] && grep -F -q -- 'provider-confirmed usage exhausted' "$scenario_error"; then
        fail "$scenario gained an exhaustion claim"
      fi
      pass "$scenario preserves its diagnostic classification"
      ;;
  esac
done

secret_catalog="$TMP_ROOT/secret-catalog.json"
secret_output="$TMP_ROOT/secret-selection.json"
secret_error="$TMP_ROOT/secret-error.log"
make_catalog unauthenticated "$secret_catalog"
jq '.models[0].preflight.access.reason="token=agy-secret-token account=private-account token=\"agy-quoted-secret value\"" | .models[0].preflight.usage.reason="secret=agy-secret-token"' "$secret_catalog" >"$secret_catalog.tmp"
mv "$secret_catalog.tmp" "$secret_catalog"
run_selector "$secret_catalog" "$secret_output" "$secret_error"
[ "$selector_exit" -eq 4 ] || fail 'secret diagnostic fixture was not rejected'
if grep -F -q -- 'agy-secret-token' "$secret_error"; then fail 'selector leaked secret diagnostic values'; fi
if grep -F -q -- 'agy-quoted-secret value' "$secret_error"; then fail 'selector leaked quoted secret diagnostic values'; fi
pass 'selector diagnostics redact secret values'

eligible_secret_catalog="$TMP_ROOT/eligible-secret-catalog.json"
eligible_secret_output="$TMP_ROOT/eligible-secret-selection.json"
eligible_secret_error="$TMP_ROOT/eligible-secret-error.log"
make_catalog verified "$eligible_secret_catalog"
jq '.models[0].preflight.access.account_ref="private-account" | .models[0].preflight.access.reason="{\"access_token\":\"agy-secret-token\",\"account_ref\":\"private-account\"} Bearer agy-secret-token token=\"agy-quoted-secret value\"" | .models[0].preflight.usage.reason="api_key=agy-secret-token"' "$eligible_secret_catalog" >"$eligible_secret_catalog.tmp"
mv "$eligible_secret_catalog.tmp" "$eligible_secret_catalog"
run_selector "$eligible_secret_catalog" "$eligible_secret_output" "$eligible_secret_error"
[ "$selector_exit" -eq 0 ] || fail 'eligible secret fixture was not selectable'
eligible_secret_text=$(cat "$eligible_secret_output.stdout" "$eligible_secret_output")
if printf '%s' "$eligible_secret_text" | grep -F -q -- 'agy-secret-token'; then fail 'eligible selection output leaked secret values'; fi
if printf '%s' "$eligible_secret_text" | grep -F -q -- 'agy-quoted-secret value'; then fail 'eligible selection output leaked quoted secret values'; fi
if printf '%s' "$eligible_secret_text" | grep -F -q -- 'private-account'; then fail 'eligible selection output leaked private account values'; fi
jq -e '.preflight.access.account_ref == "[redacted]"' "$eligible_secret_output" >/dev/null || fail 'eligible selection did not normalize the account reference'
grep -F -q -- 'Bearer [redacted]' "$eligible_secret_output.stdout" || fail 'eligible selection did not redact bearer tokens'
pass 'eligible selection output redacts secret and account values'

printf '%s\n' 'all AGY preflight checks passed'
