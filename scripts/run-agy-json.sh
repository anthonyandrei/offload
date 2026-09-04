#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --role ROLE [--route default|quality-retry] [--adapter FILE] [--selection-output FILE] [--pin FILE] --output FILE --error FILE -- worker-arguments...\n' "$0" >&2
}

fail() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-2}"; }

output_path=''
error_path=''
selection_output_path=''
pin_path=''
adapter_path=''
role=''
route='default'
seen_output=false
seen_error=false
seen_selection_output=false
seen_pin=false
seen_adapter=false
seen_role=false
seen_route=false
seen_delimiter=false
worker_args=()
required_caps=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|--error|--selection-output|--pin|--adapter|--role|--route|--require-capability)
      option="$1"
      [ "$#" -ge 2 ] || { usage; fail "$option requires a value"; }
      value="$2"
      shift 2
      case "$option" in
        --output) $seen_output && fail 'duplicate --output option'; output_path="$value"; seen_output=true ;;
        --error) $seen_error && fail 'duplicate --error option'; error_path="$value"; seen_error=true ;;
        --selection-output) $seen_selection_output && fail 'duplicate --selection-output option'; selection_output_path="$value"; seen_selection_output=true ;;
        --pin) $seen_pin && fail 'duplicate --pin option'; pin_path="$value"; seen_pin=true ;;
        --adapter) $seen_adapter && fail 'duplicate --adapter option'; adapter_path="$value"; seen_adapter=true ;;
        --role) $seen_role && fail 'duplicate --role option'; role="$value"; seen_role=true ;;
        --route) $seen_route && fail 'duplicate --route option'; route="$value"; seen_route=true ;;
        --require-capability) [ -n "$value" ] || fail '--require-capability requires a non-empty value'; required_caps+=("$value") ;;
      esac
      ;;
    --output=*|--error=*|--selection-output=*|--pin=*|--adapter=*|--role=*|--route=*|--require-capability=*)
      option="${1%%=*}"
      value="${1#*=}"
      [ -n "$value" ] || fail "$option requires a non-empty value"
      shift
      case "$option" in
        --output) $seen_output && fail 'duplicate --output option'; output_path="$value"; seen_output=true ;;
        --error) $seen_error && fail 'duplicate --error option'; error_path="$value"; seen_error=true ;;
        --selection-output) $seen_selection_output && fail 'duplicate --selection-output option'; selection_output_path="$value"; seen_selection_output=true ;;
        --pin) $seen_pin && fail 'duplicate --pin option'; pin_path="$value"; seen_pin=true ;;
        --adapter) $seen_adapter && fail 'duplicate --adapter option'; adapter_path="$value"; seen_adapter=true ;;
        --role) $seen_role && fail 'duplicate --role option'; role="$value"; seen_role=true ;;
        --route) $seen_route && fail 'duplicate --route option'; route="$value"; seen_route=true ;;
        --require-capability) required_caps+=("$value") ;;
      esac
      ;;
    --)
      seen_delimiter=true
      shift
      worker_args=("$@")
      break
      ;;
    *) usage; fail "unknown launcher option: $1" ;;
  esac
done

$seen_delimiter || { usage; fail '-- delimiter is required'; }
$seen_output && [ -n "$output_path" ] || { usage; fail '--output is required'; }
$seen_error && [ -n "$error_path" ] || { usage; fail '--error is required'; }
$seen_role && [ -n "$role" ] || { usage; fail '--role is required'; }
[ "${#worker_args[@]}" -gt 0 ] || { usage; fail 'worker arguments are required after --'; }
case "$route" in default|quality-retry) ;; *) fail "unknown route: '$route'; must be default or quality-retry" ;; esac
case "$role" in scout|gate-author|implementer|reviewer|researcher|synthesizer|auditor) ;; *) fail "unknown role: '$role'" ;; esac

i=0
while [ "$i" -lt "${#worker_args[@]}" ]; do
  arg="${worker_args[$i]}"
  case "$arg" in
    --output|--output=*) fail 'do not pass --output to the worker; use the launcher --output path instead' ;;
    --model|--model=*) fail 'caller cannot specify a model; model routing is controlled by --role and the adapter catalog' ;;
    --effort|--effort=*) fail 'caller cannot specify effort; reasoning effort is controlled by policy' ;;
    -p|--prompt|--print|--prompt-interactive|-i|--path|--output-format|--mode|--json-schema|--add-dir|--agent|--conversation|--log-file|--print-timeout|--project|--input-format)
      [ $((i + 1)) -lt "${#worker_args[@]}" ] && i=$((i + 1)) ;;
  esac
  i=$((i + 1))
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
policy_file="$repo_root/model-policy.json"
[ -f "$policy_file" ] || fail "model policy file not found at: $policy_file"
jq empty "$policy_file" >/dev/null 2>&1 || fail "model policy file is not valid JSON: $policy_file"

validation_err=$(jq -r '
  if type != "object" then "policy must be a JSON object"
  elif .schema_version != 2 then "schema_version must be integer 2"
  elif ((.policy_revision | type) != "string" or (.policy_revision | length) == 0) then "policy_revision must be a non-empty string"
  elif .max_effort != "high" then "max_effort must be high"
  elif .max_retries_per_worker != 1 then "max_retries_per_worker must be integer 1"
  elif .quota_action != "handoff" then "quota_action must be handoff"
  elif ((.roles | type) != "object") then "roles must be an object"
  elif (["scout","gate-author","implementer","reviewer","researcher","synthesizer","auditor"] - (.roles | keys) | length) != 0 then "roles missing required role"
  elif ((.roles | keys) - ["scout","gate-author","implementer","reviewer","researcher","synthesizer","auditor"] | length) != 0 then "roles contains unknown role"
  elif ([.roles[] | select((.preference | IN("fast","balanced","deep")) | not)] | length) != 0 then "role preference must be fast, balanced, or deep"
  elif ([.roles[] | select((.effort | IN("low","medium","high")) | not)] | length) != 0 then "role effort must be low, medium, or high"
  elif ([.roles[] | select((.required_capabilities | type) != "array")] | length) != 0 then "required_capabilities must be arrays"
  else "" end
' "$policy_file")
[ -z "$validation_err" ] || fail "$validation_err"

preference=$(jq -er --arg role "$role" '.roles[$role].preference' "$policy_file")
effort=$(jq -er --arg role "$role" '.roles[$role].effort' "$policy_file")
required_caps_json=$(jq -c --arg role "$role" '.roles[$role].required_capabilities' "$policy_file")
for capability in "${required_caps[@]}"; do
  required_caps_json=$(jq -c --arg capability "$capability" '. + [$capability] | unique' <<<"$required_caps_json")
done

if [ "$route" = quality-retry ] && [ -z "$pin_path" ]; then
  fail 'quality-retry requires --pin with the prior selection; use an explicit fallback or handoff when it is unavailable' 3
fi

caller_dir="$(pwd -P)"
resolve_output_path() {
  local path="$1" label="$2" parent base
  case "$path" in /*) ;; *) path="$caller_dir/$path" ;; esac
  parent="$(dirname "$path")"; base="$(basename "$path")"
  mkdir -p "$parent" || fail "could not create $label parent directory: $parent"
  printf '%s/%s' "$(cd "$parent" && pwd -P)" "$base"
}
output_path=$(resolve_output_path "$output_path" 'output path')
error_path=$(resolve_output_path "$error_path" 'error path')
[ "$output_path" != "$error_path" ] || fail 'output and error paths must be different'
if [ -n "$selection_output_path" ]; then selection_output_path=$(resolve_output_path "$selection_output_path" 'selection output path'); fi

if [ -z "$adapter_path" ]; then adapter_path="${OFFLOAD_ADAPTER_BIN:-$script_dir/agy-adapter.sh}"; fi
case "$adapter_path" in /*) ;; *) adapter_path="$caller_dir/$adapter_path" ;; esac
[ -x "$adapter_path" ] || [ -f "$adapter_path" ] || fail "adapter not found: $adapter_path" 127
adapter_cmd=("$adapter_path")

request_tmp=$(mktemp)
catalog_tmp=$(mktemp)
adapter_err_tmp=$(mktemp)
launch_selection_tmp=$(mktemp)
cleanup() { rm -f "$request_tmp" "$catalog_tmp" "$adapter_err_tmp" "$launch_selection_tmp"; }
trap cleanup EXIT

jq -n --arg role "$role" --arg preference "$preference" --arg effort "$effort" --arg policy_revision "$(jq -er '.policy_revision' "$policy_file")" --argjson caps "$required_caps_json" '{protocol_version:1,operation:"catalog",role:$role,preference:$preference,effort:$effort,required_capabilities:$caps,policy_revision:$policy_revision}' >"$request_tmp"
set +e
"${adapter_cmd[@]}" --operation catalog --request "$request_tmp" >"$catalog_tmp" 2>"$adapter_err_tmp"
catalog_code=$?
set -e
if [ "$catalog_code" -ne 0 ]; then
  diagnostic=$(tr '\n' ' ' <"$adapter_err_tmp")
  fail "adapter catalog discovery failed with exit code $catalog_code${diagnostic:+: $diagnostic}" 127
fi
jq empty "$catalog_tmp" >/dev/null 2>&1 || fail 'adapter catalog is not valid JSON' 127
catalog_adapter=$(jq -er '.adapter | strings | select(length > 0)' "$catalog_tmp") || fail 'adapter catalog is missing adapter' 127
catalog_vendor=$(jq -er '.vendor | strings | select(length > 0)' "$catalog_tmp") || fail 'adapter catalog is missing vendor' 127
catalog_revision=$(jq -er '.catalog_revision | strings | select(length > 0)' "$catalog_tmp") || fail 'adapter catalog is missing catalog_revision' 127
adapter_revision=$(jq -er '.adapter_revision | strings | select(length > 0)' "$catalog_tmp") || fail 'adapter catalog is missing adapter_revision' 127
[ "$(jq -er '.protocol_version' "$catalog_tmp")" = 1 ] || fail 'adapter catalog has unsupported protocol_version' 127

selected=$(jq -c --arg pref "$preference" --arg effort "$effort" --argjson caps "$required_caps_json" --arg vendor "$catalog_vendor" '
  [.models[]? | select((.id | type) == "string" and (.id | length) > 0)
    | select(.available == true and (.quota_available != false))
    | select((.supported_efforts // []) | index($effort))
    | select(([$caps[] as $cap | select(((.capabilities // []) | index($cap)) == null)] | length) == 0)
    | select((((.scores // {}) | has($pref)) | not) or ((((.scores // {})[$pref]) | type) == "number"))
    | {model:.,id:.id,vendor:(.vendor // $vendor),score:(if ((.scores // {}) | has($pref)) then (.scores // {})[$pref] else 1000000 end)}]
  | sort_by(.score,.vendor,.id) | .[0] // empty
' "$catalog_tmp") || true
[ -n "$selected" ] || fail "adapter catalog has no eligible model for role '$role', effort '$effort', and required capabilities" 4

selection_reason="catalog selection preference=$preference effort=$effort; filtered unavailable, quota, effort, capability, and static-policy-incompatible candidates"
if [ -n "$pin_path" ]; then
  [ -f "$pin_path" ] || fail "pinned selection file not found: $pin_path" 3
  pin_adapter=$(jq -er '.adapter // empty' "$pin_path") || fail 'pinned selection is not valid JSON' 3
  pin_vendor=$(jq -er '.vendor // empty' "$pin_path") || fail 'pinned selection is missing vendor' 3
  pin_id=$(jq -er '.model_id // .model // empty' "$pin_path") || fail 'pinned selection is missing model_id' 3
  pin_effort=$(jq -er '.effort // empty' "$pin_path") || fail 'pinned selection is missing effort' 3
  [ "$pin_adapter" = "$catalog_adapter" ] && [ "$pin_vendor" = "$catalog_vendor" ] && [ "$pin_effort" = "$effort" ] || fail 'pinned selection does not match the current adapter, vendor, or policy effort; explicit fallback or handoff is required' 3
  pinned=$(jq -c --arg id "$pin_id" --arg vendor "$pin_vendor" --arg effort "$effort" --argjson caps "$required_caps_json" '[.models[]? | select(.id == $id and ((.vendor // $vendor) == $vendor) and .available == true and (.quota_available != false) and ((.supported_efforts // []) | index($effort)) and ([$caps[] as $cap | select(((.capabilities // []) | index($cap)) == null)] | length) == 0)] | .[0] // empty' "$catalog_tmp")
  [ -n "$pinned" ] || fail "pinned model '$pin_id' is unavailable in catalog revision '$catalog_revision'; explicit fallback or handoff is required" 3
  selected=$(jq -c --argjson model "$pinned" --arg id "$pin_id" --arg vendor "$pin_vendor" '{model:$model,id:$id,vendor:$vendor,score:($model.scores // {})}' <<<"$selected")
  selection_reason="pinned selection adapter=$catalog_adapter vendor=$catalog_vendor model_id=$pin_id; catalog_revision=$catalog_revision"
fi

selection=$(jq -c --arg adapter "$catalog_adapter" --arg adapter_revision "$adapter_revision" --arg vendor "$(jq -er '.vendor' <<<"$selected")" --arg id "$(jq -er '.id' <<<"$selected")" --arg preference "$preference" --arg effort "$effort" --arg catalog_revision "$catalog_revision" --arg policy_revision "$(jq -er '.policy_revision' "$policy_file")" --arg reason "$selection_reason" --arg route "$route" --argjson caps "$required_caps_json" --argjson model "$(jq -c '.model' <<<"$selected")" '{protocol_version:1,adapter:$adapter,adapter_revision:$adapter_revision,vendor:$vendor,model_id:$id,model:$id,family_hint:($model.family_hint // null),preference:$preference,effort:$effort,catalog_revision:$catalog_revision,policy_revision:$policy_revision,required_capabilities:$caps,selection_reason:$reason,route:$route}' <<<"$selected")
if [ -n "$selection_output_path" ]; then jq . <<<"$selection" >"$selection_output_path"; fi
printf '%s\n' "$selection" >"$launch_selection_tmp"

set +e
"${adapter_cmd[@]}" --operation launch --request "$launch_selection_tmp" --output "$output_path" --error "$error_path" -- "${worker_args[@]}" >"$catalog_tmp" 2>"$adapter_err_tmp"
launch_code=$?
set -e
if [ "$launch_code" -ne 0 ] && [ -s "$adapter_err_tmp" ]; then
  printf 'ERROR: adapter launch failed with exit code %s: %s\n' "$launch_code" "$(tr '\n' ' ' <"$adapter_err_tmp")" >&2
fi
exit "$launch_code"
