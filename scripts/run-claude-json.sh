#!/usr/bin/env bash
# Launch one bounded Claude Code assignment and return an orchestrator-verifiable result.
set -u

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  if [ -n "${failure_output_path:-}" ] && command -v jq >/dev/null 2>&1; then
    jq -n --arg error "$1" '{schema_version:1,adapter:"claude",status:"failed",lifecycle:"failed",error:$error}' >"$failure_output_path" 2>/dev/null || true
  fi
  exit "${2:-2}"
}
usage() { printf 'Usage: run-claude-json.sh --assignment FILE --output FILE --error FILE\n'; }
full_path() { local p="$1"; printf '%s/%s\n' "$(cd -- "$(dirname -- "$p")" 2>/dev/null && pwd -P)" "$(basename -- "$p")"; }
same_path() { [ "$(full_path "$1")" = "$(full_path "$2")" ]; }
within_path() { local c p; c=$(full_path "$1") || return 1; p=$(full_path "$2") || return 1; case "$c" in "$p"|"$p"/*) return 0 ;; *) return 1 ;; esac; }
json_value() { jq -r "$1" "$assignment_path" 2>/dev/null; }
optional() { local v; v=$(jq -r "$1 // empty" "$assignment_path" 2>/dev/null) || fail 'invalid assignment JSON'; [ -n "$v" ] && printf '%s\n' "$v" || printf '%s\n' "$2"; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

ledger_add() {
  local id="$1" type="$2" identity="$3" state="$4" temp; temp="$ledger_path.tmp.$$"
  jq --arg id "$id" --arg aid "$assignment_id" --arg type "$type" --arg identity "$identity" --arg state "$state" --arg now "$(now_utc)" \
    '.records += [{resource_id:$id,assignment_id:$aid,parent_id:$aid,resource_type:$type,identity:$identity,owner_marker:"offload-claude-adapter-v1",state:$state,created_at:$now,updated_at:$now}]' "$ledger_path" >"$temp" || fail 'could not register resource in ledger'
  mv -- "$temp" "$ledger_path" || fail 'could not replace resource ledger'
}
ledger_update() {
  local id="$1" state="$2" key="${3:-}" value="${4:-}" temp; temp="$ledger_path.tmp.$$"
  jq --arg id "$id" --arg state "$state" --arg key "$key" --arg value "$value" \
    '(.records[] | select(.resource_id == $id)) |= (.state=$state | .updated_at=(now|todateiso8601) | if $key != "" then .[$key]=$value else . end)' "$ledger_path" >"$temp" || fail 'could not update resource ledger'
  mv -- "$temp" "$ledger_path" || fail 'could not replace resource ledger'
}

require_jq() { command -v jq >/dev/null 2>&1 || fail 'jq is required by the Claude adapter' 1; }
require_jq
assignment_path=''; output_path=''; error_path=''; failure_output_path=''; capabilities_only=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --assignment) [ "$#" -ge 2 ] || fail '--assignment requires a path'; assignment_path="$2"; shift 2 ;;
    --output) [ "$#" -ge 2 ] || fail '--output requires a path'; output_path="$2"; failure_output_path="$2"; shift 2 ;;
    --error) [ "$#" -ge 2 ] || fail '--error requires a path'; error_path="$2"; shift 2 ;;
    --capabilities) capabilities_only=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done
[ -n "$assignment_path" ] || fail '--assignment is required'
[ -n "$output_path" ] || fail '--output is required'
[ -n "$error_path" ] || fail '--error is required'
[ -f "$assignment_path" ] || fail "JSON file does not exist: $assignment_path"
schema=$(json_value '.schema_version') || fail 'invalid assignment JSON'
[ "$schema" = 1 ] || fail 'assignment schema_version must be 1'
assignment_id=$(json_value '.assignment_id') || fail 'invalid assignment JSON'
prompt=$(json_value '.prompt') || fail 'invalid assignment JSON'
workdir_raw=$(json_value '.working_directory') || fail 'invalid assignment JSON'
baseline=$(json_value '.baseline') || fail 'invalid assignment JSON'
gate_command=$(json_value '.gate_command') || fail 'invalid assignment JSON'
preference=$(json_value '.preference') || fail 'invalid assignment JSON'
[ -n "$assignment_id" ] || fail 'assignment field is required: assignment_id'
[ -n "$prompt" ] || fail 'assignment field is required: prompt'
[ -n "$workdir_raw" ] || fail 'assignment field is required: working_directory'
[ -n "$baseline" ] || fail 'assignment field is required: baseline'
[ -n "$gate_command" ] || fail 'assignment field is required: gate_command'
[ -n "$preference" ] || fail 'assignment field is required: preference'
jq -e '(.owned_paths|type=="array") and (.frozen_paths|type=="array")' "$assignment_path" >/dev/null || fail 'owned_paths and frozen_paths must be arrays'
case "$preference" in fast|balanced|deep) ;; *) fail 'preference must be fast, balanced, or deep' ;; esac
workdir=$(full_path "$workdir_raw") || fail 'could not resolve working directory'
[ -d "$workdir" ] || fail "working directory does not exist: $workdir"
marker_file="$workdir/.offload-execution-workspace"
marker_value='offload-execution-workspace-v1'
if [ ! -f "$marker_file" ]; then
  marker_file="$workdir/.offload-research-workspace"
  marker_value='offload-research-workspace-v1'
fi
[ -f "$marker_file" ] || fail 'unsupported or unmarked sandbox; use an isolated offload workspace'
[ "$(tr -d '\r\n' <"$marker_file")" = "$marker_value" ] || fail 'invalid isolated workspace marker'
same_path "$workdir" "$PWD" && fail 'working directory cannot be the caller current directory'
while IFS= read -r path; do
  normalized=${path//\\/\/}
  case "$normalized" in /*|..|../*|*/../*|*/..) fail "assignment path escapes repository: $path" ;; esac
done < <(jq -r '.owned_paths[]?, .frozen_paths[]?' "$assignment_path")
permission_mode=$(optional '.permission_mode' 'acceptEdits')
[ "$permission_mode" != bypassPermissions ] || fail 'bypassPermissions is not allowed'
if jq -e '.allowed_tools[]? | select(. == "Task" or . == "Agent")' "$assignment_path" >/dev/null 2>&1; then
  fail 'child assignment tools cannot be allowed'
fi
mkdir -p -- "$(dirname -- "$output_path")" "$(dirname -- "$error_path")" || fail 'could not create artifact directories'
out=$(full_path "$output_path") || fail 'could not resolve output path'
err=$(full_path "$error_path") || fail 'could not resolve error path'
within_path "$out" "$workdir" && fail 'result artifact must be outside the worker directory'
within_path "$err" "$workdir" && fail 'error artifact must be outside the worker directory'
repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P) || fail 'could not resolve repository root'
claude_bin="${CLAUDE_BIN:-claude}"
command -v "$claude_bin" >/dev/null 2>&1 || [ -x "$claude_bin" ] || fail 'claude was not found; set CLAUDE_BIN or add claude to PATH' 1
version_output=$("$claude_bin" --version 2>&1); version_exit_code=$?
help_output=$("$claude_bin" --help 2>&1); cli_exit_code=$?
supported_flags='[]'
for flag in print output-format input-format model permission-mode allowedTools disallowedTools resume max-turns add-dir effort; do
  if printf '%s\n' "$help_output" | grep -Eq -- "--${flag}([[:space:]=]|$)"; then supported_flags=$(jq --arg flag "$flag" '. + [$flag]' <<<"$supported_flags"); fi
done
catalog_path=$(optional '.model_catalog_path' "${CLAUDE_MODEL_CATALOG:-}")
catalog_status=unknown; catalog_source=unavailable; catalog_models='[]'
if [ -n "$catalog_path" ]; then
  [ -f "$catalog_path" ] || fail "model catalog does not exist: $catalog_path"
  jq -e '.models|type=="array"' "$catalog_path" >/dev/null || fail 'model catalog has no models array'
  catalog_models=$(jq -c '.models|map(tostring)' "$catalog_path")
  catalog_status=available; catalog_source=$(full_path "$catalog_path") || fail 'could not resolve model catalog'
fi
effort_levels='[]'; jq -e 'index("effort") != null' <<<"$supported_flags" >/dev/null && effort_levels='["low","balanced","deep"]'
capabilities=$(jq -n -c --arg version "$version_output" --argjson version_exit_code "$version_exit_code" --argjson cli_exit_code "$cli_exit_code" --argjson flags "$supported_flags" --arg source "$catalog_source" --arg cstatus "$catalog_status" --argjson models "$catalog_models" --argjson efforts "$effort_levels" \
    --argjson allowed "$(jq -c '[.allowed_tools[]?|tostring]' "$assignment_path")" --argjson denied "$(jq -c '[.disallowed_tools[]?|tostring]+["Task","Agent"]' "$assignment_path")" \
    '{version:($version|rtrimstr("\n")),version_exit_code:$version_exit_code,cli_exit_code:$cli_exit_code,supported_flags:$flags,tools:{discovered:["Read","Write","Edit","Bash","Glob","Grep","Task"],assignment_allowed:$allowed,assignment_denied:$denied},structured_output:{supported:(($flags|index("output-format"))!=null),formats:(if (($flags|index("output-format"))!=null) then ["json","stream-json","text"] else [] end)},model_catalog:{source:$source,status:$cstatus,models:$models},effort_levels:$efforts}')
if [ "$capabilities_only" = true ]; then jq -n --argjson capabilities "$capabilities" '{schema_version:1,adapter:"claude",status:"capabilities",capabilities:$capabilities}' >"$out"; exit 0; fi
jq -e '.structured_output.supported == true' <<<"$capabilities" >/dev/null || fail 'Claude CLI does not advertise structured JSON output'
pinned_model=$(optional '.model' '')
if [ -n "$pinned_model" ]; then jq -e --arg model "$pinned_model" '.model_catalog.status=="available" and (.model_catalog.models|index($model)!=null)' <<<"$capabilities" >/dev/null || fail 'pinned model is unavailable or model availability is unknown'; fi
requested_effort=$(optional '.effort' default)
if [ "$requested_effort" != default ]; then jq -e --arg effort "$requested_effort" '.effort_levels|index($effort)!=null' <<<"$capabilities" >/dev/null || fail 'requested effort is not supported by Claude host'; fi
ledger_path=$(optional '.ledger_path' '')
if [ -n "$ledger_path" ]; then
  ledger_path=$(full_path "$ledger_path") || fail 'could not resolve ledger path'
else
  ledger_path="$(dirname -- "$out")/resource-ledger.json"
fi
within_path "$ledger_path" "$workdir" && fail 'resource ledger must be outside the worker directory'
if [ -f "$ledger_path" ]; then
  jq -e '.schema_version == 1 and .owner == "orchestrator"' "$ledger_path" >/dev/null || fail 'invalid resource ledger'
else
  mkdir -p -- "$(dirname -- "$ledger_path")" || fail 'could not create ledger directory'
  jq -n --arg aid "$assignment_id" '{schema_version:1,owner:"orchestrator",assignment_id:$aid,records:[]}' >"$ledger_path" || fail 'could not create resource ledger'
fi
jq --arg aid "$assignment_id" '.assignment_id=$aid' "$ledger_path" >"$ledger_path.tmp.$$" || fail 'could not initialize resource ledger'
mv -- "$ledger_path.tmp.$$" "$ledger_path" || fail 'could not replace resource ledger'

raw_out="$out.raw.json"
raw_err="$err.raw.txt"
ledger_add worktree worktree "$workdir" created
ledger_add process process pending created
ledger_add raw-output artifact "$raw_out" created
ledger_add raw-error artifact "$raw_err" created
ledger_add result artifact "$out" created
ledger_add verification verification scope-and-gate created

timeout_text=$(optional '.timeout_seconds' 1200)
case "$timeout_text" in ''|*[!0-9]*) fail 'timeout_seconds must be a positive integer' ;; esac
[ "$timeout_text" -gt 0 ] || fail 'timeout_seconds must be a positive integer'

model_json=null
if [ -n "$pinned_model" ]; then model_json=$(jq -n --arg model "$pinned_model" '$model'); fi
  jq -n -c --arg aid "$assignment_id" --arg preference "$preference" --arg effort "$requested_effort" \
  --arg workdir "$workdir" --arg ledger "$ledger_path" --arg raw_out "$raw_out" --arg raw_err "$raw_err" --arg out "$out" \
  --argjson capabilities "$capabilities" --argjson model "$model_json" \
    '{schema_version:1,assignment_id:$aid,adapter:"claude",status:"failed",lifecycle:"created",exit_code:null,response:null,structured_output:null,session_id:null,capabilities:$capabilities,model_selection:{preference:$preference,model:$model,effort:$effort,reason:"selection is owned by the orchestrator; the adapter does not map preferences"},resources:{ledger:$ledger,worktree:$workdir,process:null},artifacts:{raw_output:$raw_out,raw_error:$raw_err,result:$out},verification:null,error:null}' >"$out" || fail 'could not initialize result artifact'

run_args=(-p "$prompt" --output-format json --permission-mode "$permission_mode" --disallowedTools Task --disallowedTools Agent)
while IFS= read -r tool; do
  [ -n "$tool" ] && run_args+=(--allowedTools "$tool")
done < <(jq -r '.allowed_tools[]? | tostring' "$assignment_path")
while IFS= read -r tool; do
  [ -n "$tool" ] && run_args+=(--disallowedTools "$tool")
done < <(jq -r '.disallowed_tools[]? | tostring' "$assignment_path")
[ -n "$pinned_model" ] && run_args+=(--model "$pinned_model")
resume_session=$(optional '.resume_session_id' '')
[ -n "$resume_session" ] && run_args+=(--resume "$resume_session")

ledger_update process started identity pending
ledger_update worktree running
ledger_update raw-output running
ledger_update raw-error running
(
  cd -- "$workdir" || exit 126
  exec "$claude_bin" "${run_args[@]}"
) >"$raw_out" 2>"$raw_err" &
process_id=$!
ledger_update process started identity "pid:$process_id"
cancel_file=$(optional '.cancel_file' '')
timed_out=false
canceled=false
terminate_worker() {
  if command -v pkill >/dev/null 2>&1; then
    pkill -TERM -P "$process_id" 2>/dev/null || true
  fi
  kill -TERM "$process_id" 2>/dev/null || true
}
worker_running() {
  if command -v ps >/dev/null 2>&1; then
    local state
    state=$(ps -o stat= -p "$process_id" 2>/dev/null | tr -d '[:space:]')
    case "$state" in ''|Z*) return 1 ;; *) return 0 ;; esac
  fi
  kill -0 "$process_id" 2>/dev/null
}
started_at=$(date +%s)
while worker_running; do
  if [ -n "$cancel_file" ] && [ -f "$cancel_file" ]; then
    canceled=true
    terminate_worker
    break
  fi
  if [ $(( $(date +%s) - started_at )) -ge "$timeout_text" ]; then
    timed_out=true
    terminate_worker
    break
  fi
  sleep 0.05
done
wait "$process_id" 2>/dev/null
exit_code=$?
cp -- "$raw_err" "$err" || fail 'could not write error artifact'

status=failed
lifecycle=failed
error_message=''
response=null
structured=null
session_id=null
verification=null
gate_output=''
if [ "$canceled" = true ]; then
  lifecycle=canceled; error_message=canceled
elif [ "$timed_out" = true ]; then
  error_message=timeout
elif grep -Eiq 'quota|rate limit|too many requests|429' "$raw_out" "$raw_err"; then
  lifecycle=quota-handoff; error_message='quota exhausted'
elif [ "$exit_code" -eq 0 ]; then
  if jq -e '(.subtype == "success") or (.status == "success")' "$raw_out" >/dev/null 2>&1; then
    response=$(jq -c 'if .result != null then .result elif .response != null then .response else null end' "$raw_out")
    session_id=$(jq -c 'if .session_id != null then .session_id else null end' "$raw_out")
    structured=$(jq -c '.' "$raw_out")
      verification=''
      scope_args=(--baseline "$baseline")
      while IFS= read -r path; do scope_args+=(--owned "$path"); done < <(jq -r '.owned_paths[]' "$assignment_path")
      while IFS= read -r path; do scope_args+=(--frozen "$path"); done < <(jq -r '.frozen_paths[]' "$assignment_path")
      scope_output=$(cd -- "$workdir" && bash "$repo_root/scripts/check-execution-scope.sh" "${scope_args[@]}" 2>&1) || {
        verification=$(jq -n --arg detail "$scope_output" '{scope:"failed",gate:"not-run",reason:"execution scope check failed",detail:$detail}')
      }
    if [ -n "$verification" ]; then
      :
    else
      verification=''
      gate_output=$(bash "$repo_root/scripts/execute-gate.sh" --command "$gate_command" --workspace "$workdir" 2>&1) || {
        verification=$(jq -n --arg detail "$gate_output" '{scope:"passed",gate:"failed",reason:"final gate failed",detail:$detail}')
      }
      if [ -z "$verification" ] && jq -e '.verification_status == "passed"' <<<"$gate_output" >/dev/null 2>&1; then
        verification='{"scope":"passed","gate":"passed","reason":"scope and final gate passed"}'
      elif [ -z "$verification" ]; then
        verification=$(jq -n --arg detail "$gate_output" '{scope:"passed",gate:"failed",reason:"final gate did not pass",detail:$detail}')
      fi
    fi
    if jq -e '.scope == "passed" and .gate == "passed"' <<<"$verification" >/dev/null 2>&1; then
      status=completed; lifecycle=completed
    else
      error_message=$(jq -r '.reason' <<<"$verification")
    fi
  else
    error_message='malformed Claude JSON output'
  fi
else
  error_message="Claude exited with code $exit_code"
fi

  jq --arg status "$status" --arg lifecycle "$lifecycle" --argjson exit_code "$exit_code" \
    --arg process_id "pid:$process_id" \
  --arg error "$error_message" --argjson response "$response" --argjson structured_output "$structured" \
  --argjson session_id "$session_id" --argjson verification "$verification" \
    '.status=$status | .lifecycle=$lifecycle | .exit_code=$exit_code | .response=$response | .structured_output=$structured_output | .session_id=$session_id | .resources.process=$process_id | .verification=$verification | .error=(if $error == "" then null else $error end)' \
  "$out" >"$out.tmp.$$" || fail 'could not finalize result artifact'
mv -- "$out.tmp.$$" "$out" || fail 'could not replace result artifact'
ledger_update process "$lifecycle"
if [ "$status" = completed ]; then ledger_update worktree completed; else ledger_update worktree retained; fi
  ledger_update raw-output retained
  ledger_update raw-error retained
  ledger_update result completed
  if [ "$verification" = null ]; then ledger_update verification not-run; elif jq -e '.scope == "passed" and .gate == "passed"' <<<"$verification" >/dev/null 2>&1; then ledger_update verification completed; else ledger_update verification failed; fi

if [ "$status" = completed ]; then exit 0; fi
if [ "$lifecycle" = quota-handoff ]; then exit 75; fi
if [ "$lifecycle" = canceled ]; then exit 130; fi
exit 1
