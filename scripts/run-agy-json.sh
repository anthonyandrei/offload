#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --role ROLE [--route default|quality-retry] --output FILE --error FILE [lifecycle options] -- agy-arguments...\n' "$0" >&2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-2}"
}

output_path=''
error_path=''
role=''
route=''
lifecycle_path=''
assignment_id=''
attempt=1
mode='unknown'
verification_baseline=''
resource_ledger_path=''
timeout_seconds=0
cancel_file=''

seen_output=false
seen_error=false
seen_role=false
seen_route=false
seen_lifecycle=false
seen_assignment_id=false
seen_attempt=false
seen_mode=false
seen_verification_baseline=false
seen_resource_ledger=false
seen_timeout=false
seen_cancel_file=false
seen_delimiter=false
worker_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      $seen_output && fail 'duplicate --output option'
      [ "$#" -ge 2 ] || { usage; fail '--output requires a path'; }
      output_path="$2"
      seen_output=true
      shift 2
      ;;
    --output=*)
      $seen_output && fail 'duplicate --output option'
      output_path="${1#--output=}"
      [ -n "$output_path" ] || { usage; fail '--output requires a path'; }
      seen_output=true
      shift
      ;;
    --error)
      $seen_error && fail 'duplicate --error option'
      [ "$#" -ge 2 ] || { usage; fail '--error requires a path'; }
      error_path="$2"
      seen_error=true
      shift 2
      ;;
    --error=*)
      $seen_error && fail 'duplicate --error option'
      error_path="${1#--error=}"
      [ -n "$error_path" ] || { usage; fail '--error requires a path'; }
      seen_error=true
      shift
      ;;
    --role)
      $seen_role && fail 'duplicate --role option'
      [ "$#" -ge 2 ] || { usage; fail '--role requires a role name'; }
      role="$2"
      seen_role=true
      shift 2
      ;;
    --role=*)
      $seen_role && fail 'duplicate --role option'
      role="${1#--role=}"
      [ -n "$role" ] || { usage; fail '--role requires a role name'; }
      seen_role=true
      shift
      ;;
    --route)
      $seen_route && fail 'duplicate --route option'
      [ "$#" -ge 2 ] || { usage; fail '--route requires a route name'; }
      route="$2"
      seen_route=true
      shift 2
      ;;
    --route=*)
      $seen_route && fail 'duplicate --route option'
      route="${1#--route=}"
      [ -n "$route" ] || { usage; fail '--route requires a route name'; }
      seen_route=true
      shift
      ;;
    --lifecycle)
      $seen_lifecycle && fail 'duplicate --lifecycle option'
      [ "$#" -ge 2 ] || { usage; fail '--lifecycle requires a path'; }
      lifecycle_path="$2"
      seen_lifecycle=true
      shift 2
      ;;
    --lifecycle=*)
      $seen_lifecycle && fail 'duplicate --lifecycle option'
      lifecycle_path="${1#--lifecycle=}"
      [ -n "$lifecycle_path" ] || { usage; fail '--lifecycle requires a path'; }
      seen_lifecycle=true
      shift
      ;;
    --assignment-id)
      $seen_assignment_id && fail 'duplicate --assignment-id option'
      [ "$#" -ge 2 ] || { usage; fail '--assignment-id requires an identifier'; }
      assignment_id="$2"
      seen_assignment_id=true
      shift 2
      ;;
    --assignment-id=*)
      $seen_assignment_id && fail 'duplicate --assignment-id option'
      assignment_id="${1#--assignment-id=}"
      [ -n "$assignment_id" ] || { usage; fail '--assignment-id requires an identifier'; }
      seen_assignment_id=true
      shift
      ;;
    --attempt)
      $seen_attempt && fail 'duplicate --attempt option'
      [ "$#" -ge 2 ] || { usage; fail '--attempt requires an integer'; }
      attempt="$2"
      seen_attempt=true
      shift 2
      ;;
    --attempt=*)
      $seen_attempt && fail 'duplicate --attempt option'
      attempt="${1#--attempt=}"
      seen_attempt=true
      shift
      ;;
    --mode)
      $seen_mode && fail 'duplicate --mode option'
      [ "$#" -ge 2 ] || { usage; fail '--mode requires a mode name'; }
      mode="$2"
      seen_mode=true
      shift 2
      ;;
    --mode=*)
      $seen_mode && fail 'duplicate --mode option'
      mode="${1#--mode=}"
      [ -n "$mode" ] || { usage; fail '--mode requires a mode name'; }
      seen_mode=true
      shift
      ;;
    --verification-baseline)
      $seen_verification_baseline && fail 'duplicate --verification-baseline option'
      [ "$#" -ge 2 ] || { usage; fail '--verification-baseline requires a value'; }
      verification_baseline="$2"
      seen_verification_baseline=true
      shift 2
      ;;
    --verification-baseline=*)
      $seen_verification_baseline && fail 'duplicate --verification-baseline option'
      verification_baseline="${1#--verification-baseline=}"
      [ -n "$verification_baseline" ] || { usage; fail '--verification-baseline requires a value'; }
      seen_verification_baseline=true
      shift
      ;;
    --resource-ledger)
      $seen_resource_ledger && fail 'duplicate --resource-ledger option'
      [ "$#" -ge 2 ] || { usage; fail '--resource-ledger requires a path'; }
      resource_ledger_path="$2"
      seen_resource_ledger=true
      shift 2
      ;;
    --resource-ledger=*)
      $seen_resource_ledger && fail 'duplicate --resource-ledger option'
      resource_ledger_path="${1#--resource-ledger=}"
      [ -n "$resource_ledger_path" ] || { usage; fail '--resource-ledger requires a path'; }
      seen_resource_ledger=true
      shift
      ;;
    --timeout-seconds)
      $seen_timeout && fail 'duplicate --timeout-seconds option'
      [ "$#" -ge 2 ] || { usage; fail '--timeout-seconds requires a positive number'; }
      timeout_seconds="$2"
      seen_timeout=true
      shift 2
      ;;
    --timeout-seconds=*)
      $seen_timeout && fail 'duplicate --timeout-seconds option'
      timeout_seconds="${1#--timeout-seconds=}"
      seen_timeout=true
      shift
      ;;
    --cancel-file)
      $seen_cancel_file && fail 'duplicate --cancel-file option'
      [ "$#" -ge 2 ] || { usage; fail '--cancel-file requires a path'; }
      cancel_file="$2"
      seen_cancel_file=true
      shift 2
      ;;
    --cancel-file=*)
      $seen_cancel_file && fail 'duplicate --cancel-file option'
      cancel_file="${1#--cancel-file=}"
      [ -n "$cancel_file" ] || { usage; fail '--cancel-file requires a path'; }
      seen_cancel_file=true
      shift
      ;;
    --)
      seen_delimiter=true
      shift
      worker_args=("$@")
      break
      ;;
    *)
      usage
      fail "unknown launcher option: $1"
      ;;
  esac
done

if ! $seen_delimiter; then
  usage
  fail '-- delimiter is required'
fi

if ! $seen_output || [ -z "$output_path" ]; then
  usage
  fail '--output is required'
fi

if ! $seen_error || [ -z "$error_path" ]; then
  usage
  fail '--error is required'
fi

if ! $seen_role || [ -z "$role" ]; then
  usage
  fail '--role is required; specify a role and remove any caller --model flag'
fi

case "$role" in
  scout|gate-author|implementer|reviewer|researcher|synthesizer|auditor) ;;
  *)
    fail "unknown role: '$role'; must be one of scout, gate-author, implementer, reviewer, researcher, synthesizer, auditor"
    ;;
esac

route="${route:-default}"
case "$route" in
  default|quality-retry) ;;
  *)
    fail "unknown route: '$route'; must be 'default' or 'quality-retry'"
    ;;
esac

if [ "${#worker_args[@]}" -eq 0 ]; then
  usage
  fail 'agy arguments are required after --'
fi

# Validate worker arguments after delimiter:
# Distinguish options from argument values for value-taking options
i=0
while [ "$i" -lt "${#worker_args[@]}" ]; do
  arg="${worker_args[$i]}"
  case "$arg" in
    --output|--output=*)
      fail 'do not pass --output to agy; use the launcher --output path instead'
      ;;
    --model|--model=*)
      fail 'caller cannot specify --model; model routing is controlled by --role'
      ;;
    --effort|--effort=*)
      fail 'caller cannot specify --effort; reasoning effort is controlled by policy'
      ;;
    -p|--prompt|--print|--prompt-interactive|-i|--path|--output-format|--mode|--json-schema|--add-dir|--agent|--conversation|--log-file|--print-timeout|--project|--input-format)
      if [ $((i + 1)) -lt "${#worker_args[@]}" ]; then
        i=$((i + 1))
      fi
      ;;
  esac
  i=$((i + 1))
done

# Resolve policy file repository-root relative to launcher location
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
policy_file="$repo_root/model-policy.json"

if [ ! -f "$policy_file" ]; then
  fail "model policy file not found at: $policy_file"
fi

if ! jq empty "$policy_file" >/dev/null 2>&1; then
  fail "model policy file is not valid JSON: $policy_file"
fi

# Comprehensive policy schema and value validation
validation_err=$(jq -r '
  def is_gemini_model:
    (type == "string") and test("^gemini-[a-zA-Z0-9.-]+-(low|medium|high)$");

  if type != "object" then
    "policy must be a JSON object"
  elif ((.schema_version | type) != "number" or .schema_version != 1 or (.schema_version | floor) != 1) then
    "schema_version must be integer 1"
  elif ((.policy_revision | type) != "string" or (.policy_revision | length) == 0) then
    "policy_revision must be a non-empty string"
  elif (.max_effort != "high") then
    "invalid max_effort: must be high"
  elif ((.max_retries_per_worker | type) != "number" or .max_retries_per_worker != 1 or (.max_retries_per_worker | floor) != 1) then
    "max_retries_per_worker must be integer 1"
  elif (.quota_action != "handoff") then
    "quota_action must be handoff"
  elif ((.roles | type) != "object") then
    "roles must be an object"
  else
    ["scout", "gate-author", "implementer", "reviewer", "researcher", "synthesizer", "auditor"] as $req |
    (.roles | keys) as $actual |
    if ([$req[] | select(. as $r | ($actual | index($r) | not))] | length) > 0 then
      "roles missing required role"
    elif ([$actual[] | select(. as $r | ($req | index($r) | not))] | length) > 0 then
      "roles contains unknown role"
    else
      ([.roles | to_entries[] | (
        .key as $rname |
        .value as $rval |
        if ($rval | type) != "object" then
          "role " + $rname + " must be an object"
        elif ($rval.default_model | is_gemini_model | not) then
          "role " + $rname + " has invalid default_model"
        elif ($rval | has("quality_escalation") | not) then
          "role " + $rname + " missing quality_escalation"
        elif ($rval.quality_escalation != null) then
          if ($rval.quality_escalation | type) != "object" then
            "role " + $rname + " quality_escalation must be null or an object"
          elif ($rval.quality_escalation.model | is_gemini_model | not) then
            "role " + $rname + " quality_escalation model is invalid"
          elif ($rval.quality_escalation.model == $rval.default_model) then
            "role " + $rname + " quality_escalation model identical to default_model"
          elif (($rval.quality_escalation.evidence_path | type) != "string" or ($rval.quality_escalation.evidence_path | length) == 0) then
            "role " + $rname + " quality_escalation evidence_path must be non-empty string"
          elif ($rval.quality_escalation.evidence_path | (startswith("/") or startswith("\\") or contains(":") or contains(".."))) then
            "role " + $rname + " quality_escalation evidence_path must not escape repository root"
          else
            empty
          end
        else
          empty
        end
      )] | first) // empty
    end
  end
' "$policy_file" 2>&1) || fail "model policy validation failed: $validation_err"

if [ -n "$validation_err" ]; then
  fail "model policy validation error: $validation_err"
fi

# Check existence of escalation evidence files
ev_paths=$(jq -r '.roles[] | select(.quality_escalation != null) | .quality_escalation.evidence_path' "$policy_file")
if [ -n "$ev_paths" ]; then
  while IFS= read -r ev_path; do
    [ -z "$ev_path" ] && continue
    if [ ! -f "$repo_root/$ev_path" ]; then
      fail "missing escalation evidence path: $ev_path"
    fi
  done <<EOF
$ev_paths
EOF
fi

# Resolve model for role and route
if [ "$route" = "default" ]; then
  resolved_model=$(jq -r --arg r "$role" '.roles[$r].default_model' "$policy_file")
elif [ "$route" = "quality-retry" ]; then
  escalation_model=$(jq -r --arg r "$role" '.roles[$r].quality_escalation.model // empty' "$policy_file")
  if [ -z "$escalation_model" ] || [ "$escalation_model" = "null" ]; then
    fail "role '$role' has no quality escalation target configured for quality-retry route"
  fi
  resolved_model="$escalation_model"
fi

[ -n "$resolved_model" ] || fail "failed to resolve model for role '$role' and route '$route'"

case "$attempt" in
  1|2) ;;
  *) fail 'attempt must be 1 or 2; policy allows at most one retry per assignment' ;;
esac
case "$timeout_seconds" in
  ''|*[!0-9]*) fail '--timeout-seconds must be zero or a positive integer' ;;
esac
assignment_id="${assignment_id:-$role-$(date -u +%Y%m%d%H%M%S)}"
lifecycle_path="${lifecycle_path:-$output_path.lifecycle.json}"
effort="${resolved_model##*-}"

# Resolve agy executable
if [ -n "${AGY_BIN:-}" ]; then
  agy_bin=$AGY_BIN
elif command -v agy >/dev/null 2>&1; then
  agy_bin=$(command -v agy)
elif [ -x "$HOME/.local/bin/agy" ]; then
  agy_bin="$HOME/.local/bin/agy"
else
  fail 'agy was not found on PATH or at ~/.local/bin/agy' 1
fi

[ -x "$agy_bin" ] || fail "agy is not executable: $agy_bin" 1

mkdir -p "$(dirname "$output_path")" "$(dirname "$error_path")" "$(dirname "$lifecycle_path")"

if [ -e "$lifecycle_path" ] && [ -d "$lifecycle_path" ]; then
  fail "lifecycle destination is an existing directory: $lifecycle_path"
fi
if [ -e "$resource_ledger_path" ] && [ -d "$resource_ledger_path" ]; then
  fail "resource ledger destination is an existing directory: $resource_ledger_path"
fi

verification_baseline_json() {
  if [ -n "$verification_baseline" ]; then
    jq -Rn --arg value "$verification_baseline" '$value'
  else
    printf 'null\n'
  fi
}

write_lifecycle() {
  baseline_json=$(verification_baseline_json)
  jq -n \
    --arg assignment_id "$assignment_id" \
    --argjson attempt "$attempt" \
    --arg role "$role" \
    --arg mode "$mode" \
    --arg policy_revision "$(jq -r '.policy_revision' "$policy_file")" \
    --arg model "$resolved_model" \
    --arg effort "$effort" \
    --argjson verification_baseline "$baseline_json" \
    --arg resource_ledger "${resource_ledger_path:-}" \
    --arg output "$output_path" \
    --arg error "$error_path" \
    --arg lifecycle "$lifecycle_path" \
    '{schema_version:1, assignment_id:$assignment_id, attempt:$attempt, role:$role, mode:$mode,
      policy_revision:$policy_revision, model:$model, effort:$effort,
      verification_baseline:$verification_baseline,
      resource_ledger:($resource_ledger | if length > 0 then . else null end), state:"created", events:[],
      exit_code:null, termination:"none", failure_class:"none",
      artifacts:{output:$output, error:$error, lifecycle:$lifecycle}}' > "$lifecycle_path"
}

record_state() {
  local state="$1"
  local event_time
  event_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg state "$state" --arg at "$event_time" \
    '.events += [{state:$state, at:$at}] | .state=$state' "$lifecycle_path" > "$lifecycle_path.tmp"
  mv -f "$lifecycle_path.tmp" "$lifecycle_path"
}

update_lifecycle() {
  local exit_code="$1"
  local termination="$2"
  local failure_class="$3"
  jq --arg termination "$termination" --arg failure_class "$failure_class" \
    --argjson exit_code "$exit_code" \
    '.exit_code=$exit_code | .termination=$termination | .failure_class=$failure_class' \
    "$lifecycle_path" > "$lifecycle_path.tmp"
  mv -f "$lifecycle_path.tmp" "$lifecycle_path"
}

write_lifecycle
record_state created

if [ -n "$resource_ledger_path" ]; then
  mkdir -p "$(dirname "$resource_ledger_path")"
  if [ -f "$resource_ledger_path" ]; then
    jq -e --arg assignment_id "$assignment_id" --arg model "$resolved_model" --arg effort "$effort" \
      '.assignment_id == $assignment_id and .model == $model and .effort == $effort' \
      "$resource_ledger_path" >/dev/null || fail 'resource ledger is pinned to a different assignment, model, or effort'
    ledger_baseline=$(jq -r '.verification_baseline // empty' "$resource_ledger_path")
    if [ -n "$ledger_baseline" ]; then
      [ -z "$verification_baseline" ] || [ "$ledger_baseline" = "$verification_baseline" ] || \
        fail 'resource ledger is pinned to a different verification baseline'
      verification_baseline="$ledger_baseline"
      jq --arg baseline "$verification_baseline" '.verification_baseline=$baseline' \
        "$lifecycle_path" > "$lifecycle_path.tmp"
      mv -f "$lifecycle_path.tmp" "$lifecycle_path"
    fi
    jq -e --argjson attempt "$attempt" 'any(.attempts[]?; .attempt == $attempt) | not' "$resource_ledger_path" >/dev/null || \
      fail "resource ledger already contains attempt $attempt"
  else
    jq -n --arg assignment_id "$assignment_id" --arg model "$resolved_model" --arg effort "$effort" \
      --argjson verification_baseline "$(verification_baseline_json)" \
      '{schema_version:1, assignment_id:$assignment_id, model:$model, effort:$effort,
        verification_baseline:$verification_baseline, attempts:[]}' > "$resource_ledger_path"
  fi
  jq --argjson attempt "$attempt" --arg model "$resolved_model" --arg effort "$effort" \
    --argjson verification_baseline "$(verification_baseline_json)" --arg lifecycle "$lifecycle_path" \
    '.attempts += [{attempt:$attempt, model:$model, effort:$effort,
      verification_baseline:$verification_baseline, lifecycle:$lifecycle}]' \
    "$resource_ledger_path" > "$resource_ledger_path.tmp"
  mv -f "$resource_ledger_path.tmp" "$resource_ledger_path"
fi

: > "$output_path"
: > "$error_path"

finalize_lifecycle() {
  if [ -f "$lifecycle_path" ]; then
    local state
    state=$(jq -r '.state' "$lifecycle_path" 2>/dev/null || true)
    case "$state" in
      completed|failed|canceled|quota-handoff)
        record_state retained
        record_state cleaned
        ;;
      retained)
        record_state cleaned
        ;;
    esac
  fi
}
trap finalize_lifecycle EXIT

if [ -n "$cancel_file" ] && [ -f "$cancel_file" ]; then
  update_lifecycle 130 canceled canceled
  record_state canceled
  exit 130
fi

set +e
"$agy_bin" --model "$resolved_model" "${worker_args[@]}" >"$output_path" 2>"$error_path" &
worker_pid=$!
set -e
record_state started
record_state running
termination='natural'
trap 'termination=canceled; kill "$worker_pid" 2>/dev/null || true' INT TERM
start_time=$(date +%s)
while kill -0 "$worker_pid" 2>/dev/null; do
  if [ -n "$cancel_file" ] && [ -f "$cancel_file" ]; then
    termination='canceled'
    kill "$worker_pid" 2>/dev/null || true
    break
  fi
  if [ "$timeout_seconds" -gt 0 ] && [ $(( $(date +%s) - start_time )) -ge "$timeout_seconds" ]; then
    termination='timeout'
    kill "$worker_pid" 2>/dev/null || true
    break
  fi
  sleep 0.05
done
set +e
wait "$worker_pid"
worker_exit=$?
set -e

if [ "$termination" = 'canceled' ]; then
  update_lifecycle 130 canceled canceled
  record_state canceled
  exit 130
fi
if [ "$termination" = 'timeout' ]; then
  update_lifecycle 124 timeout timeout
  record_state failed
  exit 124
fi
if grep -Eiq 'quota|resource[_ -]?exhausted|rate limit|(^|[^0-9])429([^0-9]|$)' "$output_path" "$error_path" 2>/dev/null; then
  update_lifecycle 75 quota-handoff quota
  record_state quota-handoff
  exit 75
fi
if [ "$worker_exit" -ne 0 ]; then
  update_lifecycle "$worker_exit" worker-exit tool_error
  record_state failed
  exit "$worker_exit"
fi
if ! jq -e 'type == "object" and .status == "success" and (.structured_output | type) == "object"' "$output_path" >/dev/null 2>&1; then
  update_lifecycle 1 malformed-output malformed_output
  record_state failed
  exit 1
fi
update_lifecycle 0 natural none
record_state completed

exit 0
