#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --role ROLE [--route default|quality-retry] --output FILE --error FILE [--ledger FILE --assignment-id ID --parent-id ID [--resource-id ID]] -- agy-arguments...\n' "$0" >&2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-2}"
}

output_path=''
error_path=''
role=''
route=''
ledger_path=''
assignment_id=''
parent_id=''
resource_id=''

seen_output=false
seen_error=false
seen_role=false
seen_route=false
seen_ledger=false
seen_assignment=false
seen_parent=false
seen_resource=false
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
    --ledger)
      $seen_ledger && fail 'duplicate --ledger option'
      [ "$#" -ge 2 ] || { usage; fail '--ledger requires a path'; }
      ledger_path="$2"
      seen_ledger=true
      shift 2
      ;;
    --ledger=*)
      $seen_ledger && fail 'duplicate --ledger option'
      ledger_path="${1#--ledger=}"
      [ -n "$ledger_path" ] || { usage; fail '--ledger requires a path'; }
      seen_ledger=true
      shift
      ;;
    --assignment-id)
      $seen_assignment && fail 'duplicate --assignment-id option'
      [ "$#" -ge 2 ] || { usage; fail '--assignment-id requires a value'; }
      assignment_id="$2"
      seen_assignment=true
      shift 2
      ;;
    --assignment-id=*)
      $seen_assignment && fail 'duplicate --assignment-id option'
      assignment_id="${1#--assignment-id=}"
      [ -n "$assignment_id" ] || { usage; fail '--assignment-id requires a value'; }
      seen_assignment=true
      shift
      ;;
    --parent-id)
      $seen_parent && fail 'duplicate --parent-id option'
      [ "$#" -ge 2 ] || { usage; fail '--parent-id requires a value'; }
      parent_id="$2"
      seen_parent=true
      shift 2
      ;;
    --parent-id=*)
      $seen_parent && fail 'duplicate --parent-id option'
      parent_id="${1#--parent-id=}"
      [ -n "$parent_id" ] || { usage; fail '--parent-id requires a value'; }
      seen_parent=true
      shift
      ;;
    --resource-id)
      $seen_resource && fail 'duplicate --resource-id option'
      [ "$#" -ge 2 ] || { usage; fail '--resource-id requires a value'; }
      resource_id="$2"
      seen_resource=true
      shift 2
      ;;
    --resource-id=*)
      $seen_resource && fail 'duplicate --resource-id option'
      resource_id="${1#--resource-id=}"
      [ -n "$resource_id" ] || { usage; fail '--resource-id requires a value'; }
      seen_resource=true
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

if $seen_ledger || $seen_assignment || $seen_parent || $seen_resource; then
  $seen_ledger && [ -n "$ledger_path" ] || fail '--ledger is required when resource ledger registration is enabled'
  $seen_assignment && [ -n "$assignment_id" ] || fail '--assignment-id is required when resource ledger registration is enabled'
  $seen_parent && [ -n "$parent_id" ] || fail '--parent-id is required when resource ledger registration is enabled'
  if ! $seen_resource; then
    resource_id="worker:$assignment_id"
  fi
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
resource_ledger="$script_dir/resource-ledger.sh"

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

mkdir -p "$(dirname "$output_path")" "$(dirname "$error_path")"

worker_pid=''
worker_done=false
ledger_registered=false

update_ledger() {
  local state="$1"
  local error_message="${2:-}"
  if $ledger_registered; then
    if [ -n "$error_message" ]; then
      "$resource_ledger" update --ledger "$ledger_path" --resource-id "$resource_id" --state "$state" --error "$error_message" >/dev/null 2>&1 || true
    else
      "$resource_ledger" update --ledger "$ledger_path" --resource-id "$resource_id" --state "$state" >/dev/null 2>&1 || true
    fi
    ledger_registered=false
  fi
}

cleanup_worker() {
  if [ -n "$worker_pid" ] && ! $worker_done && kill -0 "$worker_pid" 2>/dev/null; then
    kill "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
  fi
  if $ledger_registered; then
    update_ledger failed 'worker or launcher was interrupted'
  fi
}
trap cleanup_worker EXIT

set +e
"$agy_bin" --model "$resolved_model" "${worker_args[@]}" >"$output_path" 2>"$error_path" &
worker_pid=$!
set -e

if $seen_ledger; then
  process_start=''
  if process_start=$(ps -o lstart= -p "$worker_pid" 2>/dev/null); then
    process_start="$(printf '%s' "$process_start" | sed 's/^ *//;s/ *$//')"
  else
    process_start=''
  fi
  register_args=(register --ledger "$ledger_path" --assignment-id "$assignment_id" --parent-id "$parent_id" --resource-type worker-process --process-id "$worker_pid" --owner-marker agy-worker=agy-worker-v1 --resource-id "$resource_id" --state active)
  [ -n "$process_start" ] && register_args+=(--process-start-time "$process_start")
  if ! "$resource_ledger" "${register_args[@]}" >/dev/null; then
    cleanup_worker
    fail 'failed to register worker process in resource ledger' 1
  fi
  ledger_registered=true
fi

set +e
wait "$worker_pid"
worker_exit=$?
set -e
worker_done=true

if [ "$worker_exit" -eq 0 ]; then
  update_ledger completed
else
  update_ledger failed 'worker or launcher failed'
fi

exit "$worker_exit"
