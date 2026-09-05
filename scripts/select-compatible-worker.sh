#!/usr/bin/env bash
# Select a worker only after adapter preflight establishes access, entitlement,
# capabilities, and capacity for the complete retry budget.
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-4}"; }
catalog=''; policy=''; request=''; output=''; pin=''; provider=''; allow_unknown=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog) [ "$#" -ge 2 ] || fail '--catalog requires a value' 2; catalog=$2; shift 2 ;;
    --policy) [ "$#" -ge 2 ] || fail '--policy requires a value' 2; policy=$2; shift 2 ;;
    --request) [ "$#" -ge 2 ] || fail '--request requires a value' 2; request=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || fail '--output requires a value' 2; output=$2; shift 2 ;;
    --pin) [ "$#" -ge 2 ] || fail '--pin requires a value' 2; pin=$2; shift 2 ;;
    --provider) [ "$#" -ge 2 ] || fail '--provider requires a value' 2; provider=$2; shift 2 ;;
    --allow-unknown-usage) allow_unknown=true; shift ;;
    *) fail "unknown selector option: $1" 2 ;;
  esac
done
[ -n "$catalog" ] || fail '--catalog is required' 2
[ -n "$policy" ] || fail '--policy is required' 2
[ -n "$request" ] || fail '--request is required' 2
[ -n "$output" ] || fail '--output is required' 2
jq empty "$catalog" >/dev/null 2>&1 || fail 'adapter catalog is not valid JSON' 127
jq empty "$policy" >/dev/null 2>&1 || fail 'model policy is not valid JSON' 127
jq empty "$request" >/dev/null 2>&1 || fail 'catalog request is not valid JSON' 127
protocol=$(jq -r '.protocol_version // empty' "$catalog")
[ "$protocol" = 2 ] || fail "adapter catalog has unsupported protocol_version '$protocol'; protocol version 2 requires verified preflight records" 127
adapter=$(jq -er '.adapter|strings|select(length>0)' "$catalog") || fail 'adapter catalog is missing adapter' 127
vendor=$(jq -er '.vendor|strings|select(length>0)' "$catalog") || fail 'adapter catalog is missing vendor' 127
catalog_revision=$(jq -er '.catalog_revision|strings|select(length>0)' "$catalog") || fail 'adapter catalog is missing catalog_revision' 127
adapter_revision=$(jq -er '.adapter_revision|strings|select(length>0)' "$catalog") || fail 'adapter catalog is missing adapter_revision' 127
preference=$(jq -er '.preference|strings' "$request") || fail 'catalog request is missing preference' 127
effort=$(jq -er '.effort|strings' "$request") || fail 'catalog request is missing effort' 127
policy_revision=$(jq -er '.policy_revision|strings' "$request") || fail 'catalog request is missing policy revision' 127
assignment_units=$(jq -er '.capacity_estimation.assignment_units // 1' "$policy") || fail 'capacity estimation policy is invalid' 127
verification_units=$(jq -er '.capacity_estimation.verification_units // 1' "$policy") || fail 'capacity estimation policy is invalid' 127
retry_units=$(jq -er '.capacity_estimation.retry_units // 1' "$policy") || fail 'capacity estimation policy is invalid' 127
required_units=$((assignment_units + verification_units + retry_units))
freshness=$(jq -er '.capacity_estimation.usage_freshness_seconds // 300' "$policy") || fail 'capacity freshness policy is invalid' 127
estimate_version=$(jq -er '.capacity_estimation.version // 1' "$policy")
now=$(date -u +%s)
request_caps=$(jq -c '.required_capabilities // []' "$request")
allow_json=false; [ "$allow_unknown" = true ] && allow_json=true
pin_id=''; pin_provider=''; pin_adapter=''; pin_effort=''
if [ -n "$pin" ]; then
  [ -f "$pin" ] || fail "pinned selection file not found: $pin" 3
  pin_id=$(jq -er '.model_id // .model // empty' "$pin") || fail 'pinned selection is missing model_id' 3
  pin_adapter=$(jq -er '.adapter // empty' "$pin") || fail 'pinned selection is missing adapter' 3
  pin_provider=$(jq -r '.provider // .vendor // empty' "$pin")
  pin_effort=$(jq -er '.effort // empty' "$pin") || fail 'pinned selection is missing effort' 3
  [ "$pin_adapter" = "$adapter" ] && [ "$pin_effort" = "$effort" ] || fail 'pinned selection does not match the current adapter or policy effort; explicit fallback or handoff is required' 3
fi
unknown_usage_allowed=false
if [ "$allow_unknown" = true ] && { [ -n "$provider" ] || [ -n "$pin_provider" ]; }; then unknown_usage_allowed=true; fi

selected=$(jq -c \
  --arg effort "$effort" --arg pref "$preference" --arg vendor "$vendor" \
  --argjson caps "$request_caps" --argjson required "$required_units" \
  --argjson freshness "$freshness" --argjson now "$now" --arg provider "$provider" \
  --argjson allow_unknown "$allow_json" --argjson unknown_usage_allowed "$unknown_usage_allowed" --arg pin_id "$pin_id" --arg pin_provider "$pin_provider" '
  [.models[]? |
    (.preflight // {}) as $p | ($p.access // {}) as $a | ($p.entitlement // {}) as $e | ($p.usage // {}) as $u |
    ($u.scopes // []) as $scopes | (try (($u.observed_at // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch -1) as $observed |
    ($u.state == "known" and ($scopes|length)>0 and ($observed >= 0) and ($now - $observed >= 0) and ($now - $observed <= $freshness) and ([ $scopes[] | ((.remaining_units // -1)-(.reserved_units // -1)) >= $required ] | all)) as $usage_known |
    (.provider // .vendor // $vendor) as $model_provider |
    select((.id|type)=="string" and (.id|length)>0) |
    select((has("available")|not) or .available == true) |
    select((has("quota_available")|not) or .quota_available == true) |
    select(($a.state // "") | IN("verified","authenticated","available")) |
    select(($a.account_ref // "") | length > 0) |
    select(($e.state // "") | IN("active","continuing")) |
    select(((($e.billing_route // "") | length) > 0) and (($e.billing_route // "") != "paid-fallback") and (($e.billing_route // "") != "unknown")) |
    select((.supported_efforts // []) | index($effort)) |
    select([ $caps[] as $cap | select(((.capabilities // [])|index($cap)) == null) ] | length == 0) |
    select($usage_known or ($unknown_usage_allowed and ($u.state // "") != "exhausted")) |
    select(($provider|length)==0 or $model_provider==$provider or (.adapter // "")==$provider or (.vendor // "")==$provider) |
    select(($pin_id|length)==0 or (.id==$pin_id and $model_provider==$pin_provider)) |
    {model:.,id:.id,provider:$model_provider,score:((.scores // {})[$pref] // 1000000),remaining:(if $usage_known then ([ $scopes[] | (.remaining_units-.reserved_units) ] | min) else -1 end),usage_known:$usage_known}
  ] | sort_by(.score, (0-.remaining), .provider, .id) | .[0] // empty' "$catalog") || true
[ -n "$selected" ] || { [ -z "$pin" ] || fail 'pinned model is unavailable or no longer eligible; explicit fallback or handoff is required' 3; [ -z "$provider" ] || fail "explicit provider '$provider' is not eligible; no silent fallback is permitted" 3; fail 'no eligible worker: verified access, active entitlement, required capability, and capacity for assignment + verification + one retry are required' 4; }

if [ -n "$pin" ]; then
  reason="pinned selection adapter=$adapter provider=$pin_provider model_id=$pin_id; preflight revalidated"
else
  if [ -n "$provider" ]; then
    reason="explicit provider '$provider' selected after eligibility checks; no fallback"
  else
    reason="selected by preference=$preference, capability match, and remaining capacity; estimate units=$required_units (assignment=$assignment_units, verification=$verification_units, retry=$retry_units)"
  fi
fi

selection=$(jq -n --argjson s "$selected" --arg adapter "$adapter" --arg adapter_revision "$adapter_revision" --arg vendor "$vendor" --arg preference "$preference" --arg effort "$effort" --arg catalog_revision "$catalog_revision" --arg policy_revision "$policy_revision" --arg reason "$reason" --argjson caps "$request_caps" --arg route "$(jq -r '.route // "default"' "$request")" --argjson estimate_version "$estimate_version" --argjson assignment_units "$assignment_units" --argjson verification_units "$verification_units" --argjson retry_units "$retry_units" --argjson required_units "$required_units" --argjson freshness "$freshness" '{protocol_version:2,adapter:$adapter,adapter_revision:$adapter_revision,vendor:$vendor,provider:$s.provider,model_id:$s.id,model:$s.id,family_hint:($s.model.family_hint // ""),preference:$preference,effort:$effort,catalog_revision:$catalog_revision,policy_revision:$policy_revision,required_capabilities:$caps,selection_reason:$reason,route:$route,eligibility:"eligible",eligibility_reason:"verified access, active entitlement, compatible capabilities, and sufficient capacity",preflight:$s.model.preflight,capacity_estimate:{version:$estimate_version,assignment_units:$assignment_units,verification_units:$verification_units,retry_units:$retry_units,required_units:$required_units,freshness_seconds:$freshness},usage_observed_at:($s.model.preflight.usage.observed_at // ""),usage_uncertain:($s.usage_known|not),reservation:{required_units:$required_units,scopes:[$s.model.preflight.usage.scopes[]?.scope_id]}}')
printf '%s' "$selection" >"$output"
printf '%s' "$selection"
