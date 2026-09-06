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
  def text($value): if $value == null then "" else ($value|tostring) end;
  def state($value): text($value) | ascii_downcase;
  def safe($value):
    text($value)
    | gsub("[\\r\\n\\t]+"; " ")
     | gsub("(?i)(access[_-]?token|api[_-]?key|token|secret|password|authorization|account([_-]?ref)?|billing([_-]?route)?)[=:][[:space:]]*(\\\"[^\\\"]*\\\"|\u0027[^\u0027]*\u0027|[^,[:space:]}]+)"; "[redacted]")
    | gsub("(?i)\\\"(access[_-]?token|api[_-]?key|token|secret|password|authorization|account([_-]?ref)?|billing([_-]?route)?)\\\"[[:space:]]*:[[:space:]]*\\\"[^\\\"]*\\\""; "\\\"\\1\\\":\\\"[redacted]\\\"")
    | gsub("(?i)bearer[[:space:]]+[^[:space:]]+"; "Bearer [redacted]")
    | if length > 240 then .[0:240] else . end;
  def billing_allowed($route): ["included","subscription","test-subscription","probe-subscription","free","trial","community","enterprise"] | index(state($route)) != null;
  def usage_reason($u):
    (state($u.state)) as $s
    | (if (text($u.reason)|length)>0 then safe($u.reason) else (if ($s|length)>0 then "state=\($s)" else "state was not reported" end) end) as $r
    | if $s == "exhausted" then "provider-confirmed usage exhausted: \($r)"
      elif $s == "malformed" then "usage observation is malformed: \($r)"
      elif $s == "stale" then "usage observation is stale: \($r)"
      elif $s == "timed-out" then "usage probe timed out: \($r)"
      else "usage verification unavailable or unsupported: \($r)" end;
  def safe_preflight:
    (.preflight // {}) as $p | ($p.access // {}) as $a | ($p.entitlement // {}) as $e | ($p.usage // {}) as $u |
    {
      access:{state:state($a.state),reason:safe($a.reason),account_ref:(if (text($a.account_ref)|length)>0 then "[redacted]" else "" end)},
      entitlement:{state:state($e.state),reason:safe($e.reason),billing_route:state($e.billing_route),cancellation_pending:(if ($e.cancellation_pending|type)=="boolean" then $e.cancellation_pending else false end)},
      usage:{state:state($u.state),reason:safe($u.reason),source:safe($u.source),observed_at:safe($u.observed_at),scopes:(if (($u.scopes // null)|type)=="array" then [$u.scopes[]? | select(type=="object") | select((.remaining_units|type)=="number" and (.reserved_units|type)=="number") | {scope_id:safe(.scope_id),remaining_units:.remaining_units,reserved_units:.reserved_units}] else [] end)}
    };
  [.models[]? |
    (.preflight // {}) as $p | ($p.access // {}) as $a | ($p.entitlement // {}) as $e | ($p.usage // {}) as $u |
    (if (($u.scopes // null)|type)=="array" then $u.scopes else [] end) as $scopes |
    (try (($u.observed_at // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch -1) as $observed |
    (state($u.state) == "known" and ($scopes|length)>0 and ($observed >= 0) and ($now - $observed >= 0) and ($now - $observed <= $freshness) and ([ $scopes[] | ((.remaining_units|type)=="number" and (.reserved_units|type)=="number") ] | all)) as $usage_observed |
    ($usage_observed and ([ $scopes[] | (.remaining_units-.reserved_units) >= $required ] | all)) as $capacity_sufficient |
    ($usage_observed and $capacity_sufficient) as $usage_known |
    (.provider // .vendor // $vendor) as $model_provider |
    select((.id|type)=="string" and (.id|length)>0) |
    select((has("available")|not) or .available == true) |
    select((has("quota_available")|not) or .quota_available == true) |
    select(state($a.state) | IN("verified","authenticated","available")) |
    select(($a.account_ref|type) == "string" and ($a.account_ref|length) > 0) |
    select(state($e.state) | IN("active","continuing")) |
    select(billing_allowed($e.billing_route)) |
    select((.supported_efforts // []) | index($effort)) |
    select([ $caps[] as $cap | select(((.capabilities // [])|index($cap)) == null) ] | length == 0) |
    select($usage_known or ($unknown_usage_allowed and state($u.state) != "exhausted" and ($usage_observed|not))) |
    select(($provider|length)==0 or $model_provider==$provider or (.adapter // "")==$provider or (.vendor // "")==$provider) |
    select(($pin_id|length)==0 or (.id==$pin_id and $model_provider==$pin_provider)) |
    {model:.,id:.id,provider:$model_provider,score:((.scores // {})[$pref] // 1000000),remaining:(if $usage_known then ([ $scopes[] | (.remaining_units-.reserved_units) ] | min) else -1 end),usage_known:$usage_known,preflight:(safe_preflight),preflight_reasons:(if $usage_known then [] else [usage_reason($u)] end)}
  ] | sort_by(.score, (0-.remaining), .provider, .id) | .[0] // empty' "$catalog") || true

diagnostics=$(jq -r \
  --arg effort "$effort" --arg vendor "$vendor" --argjson caps "$request_caps" \
  --argjson required "$required_units" --argjson freshness "$freshness" --argjson now "$now" \
  --arg provider "$provider" --arg pin_id "$pin_id" --arg pin_provider "$pin_provider" '
  def text($value): if $value == null then "" else ($value|tostring) end;
  def safe($value):
    text($value)
    | gsub("[\\r\\n\\t]+"; " ")
     | gsub("(?i)(access[_-]?token|api[_-]?key|token|secret|password|authorization|account([_-]?ref)?|billing([_-]?route)?)[=:][[:space:]]*(\\\"[^\\\"]*\\\"|\u0027[^\u0027]*\u0027|[^,[:space:]}]+)"; "[redacted]")
    | gsub("(?i)\\\"(access[_-]?token|api[_-]?key|token|secret|password|authorization|account([_-]?ref)?|billing([_-]?route)?)\\\"[[:space:]]*:[[:space:]]*\\\"[^\\\"]*\\\""; "\\\"\\1\\\":\\\"[redacted]\\\"")
    | gsub("(?i)bearer[[:space:]]+[^[:space:]]+"; "Bearer [redacted]")
    | if length > 240 then .[0:240] else . end;
  def state($value): text($value) | ascii_downcase;
  def billing_allowed($route): ["included","subscription","test-subscription","probe-subscription","free","trial","community","enterprise"] | index(state($route)) != null;
  def record_reason($value; $fallback): if (text($value)|length)>0 then safe($value) else $fallback end;
  def access_reason($a):
    (state($a.state)) as $s
    | (record_reason($a.reason; (if ($s|length)>0 then "state=\($s)" else "state was not reported" end))) as $r
    | if (["denied","rejected","unauthenticated","forbidden"]|index($s)) then "provider-confirmed access failure: \($r)"
      elif (["expired","revoked"]|index($s)) then "provider-confirmed access \($s): \($r)"
      else "access verification unavailable or unsupported: \($r)" end;
  def entitlement_reason($e):
    (state($e.state)) as $s
    | (record_reason($e.reason; (if ($s|length)>0 then "state=\($s)" else "state was not reported" end))) as $r
    | if (["denied","rejected","forbidden","expired","revoked"]|index($s)) then "provider-confirmed entitlement \($s): \($r)"
      else "entitlement verification unavailable or unsupported: \($r)" end;
  def billing_reason($e):
    (state($e.billing_route)) as $s
    | if $s == "paid-fallback" then "billing route is a provider-confirmed paid fallback"
      elif (["denied","rejected","forbidden","expired","revoked","disallowed"]|index($s)) then "provider-confirmed billing failure: \(record_reason($e.reason; "billing route was rejected"))"
      else "billing verification unavailable or unsupported: \(record_reason($e.reason; (if ($s|length)>0 then "route=\($s)" else "billing route was not reported" end)) )" end;
  def usage_reason($u):
    (state($u.state)) as $s
    | (record_reason($u.reason; (if ($s|length)>0 then "state=\($s)" else "state was not reported" end))) as $r
    | if $s == "exhausted" then "provider-confirmed usage exhausted: \($r)"
      elif $s == "malformed" then "usage observation is malformed: \($r)"
      elif $s == "stale" then "usage observation is stale: \($r)"
      elif $s == "timed-out" then "usage probe timed out: \($r)"
      else "usage verification unavailable or unsupported: \($r)" end;
  def candidate_reasons:
    (.preflight // {}) as $p | ($p.access // {}) as $a | ($p.entitlement // {}) as $e | ($p.usage // {}) as $u
    | (.id // "") as $id | (state($a.state)) as $as | (state($e.state)) as $es | (state($e.billing_route)) as $bs | (state($u.state)) as $us
    | (if (($u.scopes // null)|type)=="array" then $u.scopes else [] end) as $scopes
    | (try (($u.observed_at // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch -1) as $observed
    | ($us == "known" and ($scopes|length)>0 and ($observed >= 0) and ($now - $observed >= 0) and ($now - $observed <= $freshness) and ([ $scopes[] | ((.remaining_units|type)=="number" and (.reserved_units|type)=="number") ] | all)) as $usage_observed
    | ($usage_observed and ([ $scopes[] | (.remaining_units-.reserved_units) >= $required ] | all)) as $capacity_sufficient
    | [
        (if ($id|type)!="string" or ($id|length)==0 then "missing model id" else null end),
        (if ((has("available")) and .available == false) then "adapter marked model unavailable" else null end),
        (if ((has("quota_available")) and .quota_available == false) then "adapter marked quota unavailable" else null end),
        (if ($as|IN("verified","authenticated","available")) then (if (text($a.account_ref)|length)==0 then "access is verified but the account identifier is missing" else null end) else access_reason($a) end),
        (if ($es|IN("active","continuing")) then null else entitlement_reason($e) end),
        (if billing_allowed($e.billing_route) then null else billing_reason($e) end),
        (if ((.supported_efforts // []) | index($effort)) then null else "effort is unsupported" end),
        ([ $caps[] as $cap | select(((.capabilities // [])|index($cap)) == null) | "missing capability \($cap)" ]),
        (if $us == "exhausted" then usage_reason($u)
         elif $usage_observed and ($capacity_sufficient|not) then ([ $scopes[] | "provider-confirmed capacity insufficient in scope \(safe(.scope_id))" ] | .[]?)
         elif $us == "known" then "usage observation is malformed or incomplete"
         else usage_reason($u) end),
        (if ($provider|length)>0 and ((.provider // .vendor // $vendor) != $provider) then "model provider does not match explicit provider" else null end),
        (if ($pin_id|length)>0 and ((.id != $pin_id) or ((.provider // .vendor // $vendor) != $pin_provider)) then "model does not match the pinned provider and model" else null end)
      ] | flatten | map(select(. != null and (.|tostring|length)>0)) | unique;
  [.models[]? | {id:(.id // "<missing>"), reasons:candidate_reasons} | select(.reasons|length>0) | "\(safe(.id)): \(.reasons|map(safe(.))|join(", "))"] | .[]
' "$catalog" 2>/dev/null || true)

if [ -z "$selected" ]; then
  detail=''
  [ -n "$diagnostics" ] && detail="; $diagnostics"
  if [ -n "$pin" ]; then fail "pinned model is unavailable or no longer eligible; explicit fallback or handoff is required$detail" 3; fi
  if [ -n "$provider" ]; then fail "explicit provider '$provider' is not eligible; no silent fallback is permitted$detail" 3; fi
  fail "no eligible worker: verified access, active entitlement, required capability, and capacity for assignment + verification + one retry are required$detail" 4
fi

if [ -n "$pin" ]; then
  reason="pinned selection adapter=$adapter provider=$pin_provider model_id=$pin_id; preflight revalidated"
else
  if [ -n "$provider" ]; then
    reason="explicit provider '$provider' selected after eligibility checks; no fallback"
  else
    reason="selected by preference=$preference, capability match, and remaining capacity; estimate units=$required_units (assignment=$assignment_units, verification=$verification_units, retry=$retry_units)"
  fi
fi

selection=$(jq -n --argjson s "$selected" --arg adapter "$adapter" --arg adapter_revision "$adapter_revision" --arg vendor "$vendor" --arg preference "$preference" --arg effort "$effort" --arg catalog_revision "$catalog_revision" --arg policy_revision "$policy_revision" --arg reason "$reason" --argjson caps "$request_caps" --arg route "$(jq -r '.route // "default"' "$request")" --argjson estimate_version "$estimate_version" --argjson assignment_units "$assignment_units" --argjson verification_units "$verification_units" --argjson retry_units "$retry_units" --argjson required_units "$required_units" --argjson freshness "$freshness" '{protocol_version:2,adapter:$adapter,adapter_revision:$adapter_revision,vendor:$vendor,provider:$s.provider,model_id:$s.id,model:$s.id,family_hint:($s.model.family_hint // ""),preference:$preference,effort:$effort,catalog_revision:$catalog_revision,policy_revision:$policy_revision,required_capabilities:$caps,selection_reason:$reason,route:$route,eligibility:"eligible",eligibility_reason:"verified access, active entitlement, compatible capabilities, and sufficient capacity",preflight:$s.preflight,preflight_reasons:$s.preflight_reasons,capacity_estimate:{version:$estimate_version,assignment_units:$assignment_units,verification_units:$verification_units,retry_units:$retry_units,required_units:$required_units,freshness_seconds:$freshness},usage_observed_at:($s.preflight.usage.observed_at // ""),usage_uncertain:($s.usage_known|not),reservation:{required_units:$required_units,scopes:[$s.preflight.usage.scopes[]?.scope_id]}}')
printf '%s' "$selection" >"$output"
printf '%s' "$selection"
