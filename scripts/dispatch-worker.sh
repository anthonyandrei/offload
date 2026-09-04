#!/usr/bin/env bash
# Orchestrator-only assignment admission, worktree creation, and worker launch.

set -euo pipefail

STATE_MARKER='offload-dispatch-state-v1'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LAUNCHER="$SCRIPT_DIR/run-agy-json.sh"
WORKSPACE_HELPER="$SCRIPT_DIR/execution-workspace.sh"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-2}"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  dispatch-worker.sh --state FILE --assignment-id ID [--parent-assignment-id ID]
    --role ROLE --source-repo DIR --baseline REV --owned PATH [--owned PATH ...]
    --output FILE --error FILE --timeout-seconds N --resource-units N
    [--max-depth N --max-width N --max-timeout-seconds N --max-resource-units N]
    [--frozen PATH ...] [--workspace-dir DIR] [--workspace-manifest FILE] -- agy-arguments...
EOF
}

require_jq() {
  command -v jq >/dev/null 2>&1 || fail 'jq is required by dispatch-worker.sh' 1
}

now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

canonical_path() {
  local value="$1"
  local dir base cwd
  if [ -d "$value" ]; then
    (cd "$value" && pwd -P)
    return
  fi
  dir=$(dirname "$value")
  base=$(basename "$value")
  if [ -d "$dir" ]; then
    printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
  else
    cwd=$(pwd -P)
    case "$value" in
      /*) printf '%s\n' "$value" ;;
      *) printf '%s/%s\n' "$cwd" "$value" ;;
    esac
  fi
}

write_state() {
  local state_file="$1"
  local tmp_file="${state_file}.$$.tmp"
  jq '.' "$state_file" >"$tmp_file" || { rm -f "$tmp_file"; fail "failed to serialize dispatch ledger: $state_file" 1; }
  mv -f "$tmp_file" "$state_file"
}

acquire_lock() {
  local state_file="$1"
  local lock_dir="${state_file}.lock"
  local start
  mkdir -p "$(dirname "$state_file")"
  start=$(date +%s)
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ $(( $(date +%s) - start )) -ge 15 ]; then
      fail "timed out acquiring dispatch ledger lock: $state_file" 1
    fi
    sleep 0.025
  done
  printf '%s\n' "$lock_dir"
}

release_lock() {
  local lock_dir="$1"
  rmdir "$lock_dir" 2>/dev/null || true
}

record_rejection() {
  local state_file="$1" assignment_id="$2" reason="$3" role_value="$4" parent_value="$5"
  [ -f "$state_file" ] || return 0
  local lock
  lock=$(acquire_lock "$state_file")
  local actor='orchestrator'
  [ "${OFFLOAD_WORKER_CONTEXT:-}" = '1' ] && actor='worker'
  jq --arg marker "$STATE_MARKER" \
     --arg actor "$actor" \
     --arg assignment "$assignment_id" \
     --arg reason_value "$reason" \
     --arg role_value "$role_value" \
     --arg parent_value "$parent_value" \
     --arg recorded "$(now)" \
     '. as $state |
      .events += [{type:"nested_dispatch_rejected", actor:$actor, assignment_id:$assignment,
        reason:$reason_value, request:{role:$role_value, parent_assignment_id:(if $parent_value == "" then null else $parent_value end)},
        recorded_at:$recorded}]' "$state_file" >"${state_file}.$$.tmp"
  mv -f "${state_file}.$$.tmp" "$state_file"
  release_lock "$lock"
}

append_rejection_locked() {
  local state_file="$1" assignment_id="$2" reason="$3" request_json="$4"
  jq --arg actor orchestrator --arg assignment "$assignment_id" --arg reason_value "$reason" --arg recorded "$(now)" --argjson request "$request_json" \
    '.events += [{type:"nested_dispatch_rejected",actor:$actor,assignment_id:$assignment,reason:$reason_value,request:$request,recorded_at:$recorded}]' \
    "$state_file" >"${state_file}.$$.tmp"
  mv -f "${state_file}.$$.tmp" "$state_file"
}

parse_positive_int() {
  local name="$1" value="$2" allow_zero="$3"
  case "$value" in ''|*[!0-9]*) fail "$name must be an integer: $value" ;; esac
  if [ "$allow_zero" = true ]; then
    [ "$value" -ge 0 ] || fail "$name must be non-negative"
  else
    [ "$value" -gt 0 ] || fail "$name must be positive"
  fi
}

require_jq

state_file=''
assignment_id=''
parent_id=''
role=''
source_repo=''
baseline=''
output_path=''
error_path=''
workspace_dir=''
workspace_manifest=''
max_depth=''
max_width=''
max_timeout=''
max_resources=''
depth_arg=''
timeout_arg=''
resources_arg=''
owned_paths=()
frozen_paths=()
worker_args=()
seen_delimiter=false

while [ "$#" -gt 0 ]; do
  if $seen_delimiter; then
    worker_args+=("$1")
    shift
    continue
  fi
  case "$1" in
    --)
      seen_delimiter=true; shift ;;
    --state|--assignment-id|--parent-assignment-id|--role|--source-repo|--baseline|--owned|--frozen|--output|--error|--workspace-dir|--workspace-manifest|--max-depth|--max-width|--max-timeout-seconds|--max-resource-units|--depth|--timeout-seconds|--resource-units)
      option="$1"
      [ "$#" -ge 2 ] || { usage; fail "$option requires a value"; }
      value="$2"
      shift 2
      case "$option" in
        --state) state_file="$value" ;;
        --assignment-id) assignment_id="$value" ;;
        --parent-assignment-id) parent_id="$value" ;;
        --role) role="$value" ;;
        --source-repo) source_repo="$value" ;;
        --baseline) baseline="$value" ;;
        --owned) owned_paths+=("$value") ;;
        --frozen) frozen_paths+=("$value") ;;
        --output) output_path="$value" ;;
        --error) error_path="$value" ;;
        --workspace-dir) workspace_dir="$value" ;;
        --workspace-manifest) workspace_manifest="$value" ;;
        --max-depth) max_depth="$value" ;;
        --max-width) max_width="$value" ;;
        --max-timeout-seconds) max_timeout="$value" ;;
        --max-resource-units) max_resources="$value" ;;
        --depth) depth_arg="$value" ;;
        --timeout-seconds) timeout_arg="$value" ;;
        --resource-units) resources_arg="$value" ;;
      esac
      ;;
    --state=*|--assignment-id=*|--parent-assignment-id=*|--role=*|--source-repo=*|--baseline=*|--owned=*|--frozen=*|--output=*|--error=*|--workspace-dir=*|--workspace-manifest=*|--max-depth=*|--max-width=*|--max-timeout-seconds=*|--max-resource-units=*|--depth=*|--timeout-seconds=*|--resource-units=*)
      option="${1%%=*}"; value="${1#*=}"; shift
      [ -n "$value" ] || fail "$option requires a value"
      case "$option" in
        --state) state_file="$value" ;; --assignment-id) assignment_id="$value" ;;
        --parent-assignment-id) parent_id="$value" ;; --role) role="$value" ;;
        --source-repo) source_repo="$value" ;; --baseline) baseline="$value" ;;
        --owned) owned_paths+=("$value") ;; --frozen) frozen_paths+=("$value") ;;
        --output) output_path="$value" ;; --error) error_path="$value" ;;
        --workspace-dir) workspace_dir="$value" ;; --workspace-manifest) workspace_manifest="$value" ;;
        --max-depth) max_depth="$value" ;; --max-width) max_width="$value" ;;
        --max-timeout-seconds) max_timeout="$value" ;; --max-resource-units) max_resources="$value" ;;
        --depth) depth_arg="$value" ;; --timeout-seconds) timeout_arg="$value" ;;
        --resource-units) resources_arg="$value" ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown dispatcher option: $1" ;;
  esac
done

$seen_delimiter || { usage; fail '-- delimiter is required'; }
[ "${#worker_args[@]}" -gt 0 ] || { usage; fail 'agy arguments are required after --'; }
[ -n "$state_file" ] || { usage; fail '--state is required'; }
[ -n "$assignment_id" ] || { usage; fail '--assignment-id is required'; }
[ -n "$role" ] || { usage; fail '--role is required'; }
[ -n "$source_repo" ] || { usage; fail '--source-repo is required'; }
[ -n "$baseline" ] || { usage; fail '--baseline is required'; }
[ -n "$output_path" ] || { usage; fail '--output is required'; }
[ -n "$error_path" ] || { usage; fail '--error is required'; }
[ "${#owned_paths[@]}" -gt 0 ] || fail 'at least one --owned path is required'
[ -n "$timeout_arg" ] || fail '--timeout-seconds is required'
[ -n "$resources_arg" ] || fail '--resource-units is required'
[[ "$assignment_id" != *[[:space:]/\\]* ]] || fail '--assignment-id cannot contain whitespace or path separators'
parse_positive_int '--timeout-seconds' "$timeout_arg" false
parse_positive_int '--resource-units' "$resources_arg" false

if [ -n "$max_depth" ]; then parse_positive_int '--max-depth' "$max_depth" true; fi
if [ -n "$max_width" ]; then parse_positive_int '--max-width' "$max_width" false; fi
if [ -n "$max_timeout" ]; then parse_positive_int '--max-timeout-seconds' "$max_timeout" false; fi
if [ -n "$max_resources" ]; then parse_positive_int '--max-resource-units' "$max_resources" false; fi
if [ -n "$depth_arg" ]; then parse_positive_int '--depth' "$depth_arg" true; fi

if [ "${OFFLOAD_WORKER_CONTEXT:-}" = '1' ]; then
  record_rejection "$state_file" "$assignment_id" 'worker context cannot create assignments, processes, or worktrees' "$role" "$parent_id"
  fail 'worker dispatch rejected: only the orchestrator may create assignments, processes, or worktrees' 126
fi

state_file=$(canonical_path "$state_file")
if [ -z "$workspace_manifest" ]; then
  workspace_manifest="$(dirname "$state_file")/${assignment_id}.manifest.json"
fi
lock=$(acquire_lock "$state_file")
if [ -z "$parent_id" ]; then
  [ -n "$max_depth" ] && [ -n "$max_width" ] && [ -n "$max_timeout" ] && [ -n "$max_resources" ] || { release_lock "$lock"; fail 'root dispatch requires all maximum limits'; }
elif [ ! -f "$state_file" ]; then
  release_lock "$lock"
  fail "dispatch ledger does not exist: $state_file"
fi

if [ ! -f "$state_file" ]; then
  jq -n --argjson md "$max_depth" --argjson mw "$max_width" --argjson mt "$max_timeout" --argjson mr "$max_resources" --arg marker "$STATE_MARKER" --arg created "$(now)" \
    '{schema_version:1, marker:$marker, limits:{max_depth:$md,max_width:$mw,max_timeout_seconds:$mt,max_resource_units:$mr}, assignments:[], events:[], created_at:$created}' >"$state_file"
fi
jq -e --arg marker "$STATE_MARKER" '(.marker == $marker and .schema_version == 1 and (.limits and .assignments and .events))' "$state_file" >/dev/null || { release_lock "$lock"; fail "invalid dispatch ledger: $state_file"; }

if [ -n "$parent_id" ]; then
  for pair in max_depth max_width max_timeout max_resources; do
    value="${!pair}"
    limit_key="$pair"
    [ "$pair" = max_timeout ] && limit_key=max_timeout_seconds
    [ "$pair" = max_resources ] && limit_key=max_resource_units
    if [ -n "$value" ]; then
      actual_limit=$(jq -r ".limits.$limit_key" "$state_file")
      if [ "$value" -ne "$actual_limit" ]; then
        request_json=$(jq -cn --arg parent "$parent_id" --arg limit "$limit_key" --argjson requested "$value" --argjson allowed "$actual_limit" '{parent_assignment_id:$parent,limit:$limit,requested:$requested,allowed:$allowed}')
        append_rejection_locked "$state_file" "$assignment_id" 'child attempted to widen an immutable dispatch limit' "$request_json"
        release_lock "$lock"
        fail "child cannot change dispatch limit --$limit_key" 126
      fi
    fi
  done
  parent_count=$(jq --arg p "$parent_id" '[.assignments[] | select(.assignment_id == $p)] | length' "$state_file")
  [ "$parent_count" -eq 1 ] || { release_lock "$lock"; fail "parent assignment does not exist uniquely: $parent_id"; }
  parent_depth=$(jq -r --arg p "$parent_id" '.assignments[] | select(.assignment_id == $p) | .depth' "$state_file")
  depth=$((parent_depth + 1))
else
  depth=0
fi
[ -z "$depth_arg" ] || [ "$depth_arg" -eq "$depth" ] || { release_lock "$lock"; fail '--depth does not match parent depth'; }
max_depth_value=$(jq -r '.limits.max_depth' "$state_file")
max_width_value=$(jq -r '.limits.max_width' "$state_file")
max_timeout_value=$(jq -r '.limits.max_timeout_seconds' "$state_file")
max_resources_value=$(jq -r '.limits.max_resource_units' "$state_file")
[ "$depth" -le "$max_depth_value" ] || { append_rejection_locked "$state_file" "$assignment_id" 'maximum dispatch depth exceeded' "$(jq -cn --arg parent "$parent_id" --argjson depth "$depth" --argjson max_depth "$max_depth_value" '{parent_assignment_id:(if $parent == "" then null else $parent end),depth:$depth,max_depth:$max_depth}')"; release_lock "$lock"; fail 'dispatch rejected: maximum depth exceeded' 126; }
if [ -n "$parent_id" ]; then
  child_count=$(jq --arg p "$parent_id" '[.assignments[] | select(.parent_assignment_id == $p)] | length' "$state_file")
  [ "$child_count" -lt "$max_width_value" ] || { append_rejection_locked "$state_file" "$assignment_id" 'maximum child width exceeded' "$(jq -cn --arg parent "$parent_id" --argjson width "$((child_count + 1))" --argjson max_width "$max_width_value" '{parent_assignment_id:$parent,width:$width,max_width:$max_width}')"; release_lock "$lock"; fail 'dispatch rejected: maximum child width exceeded' 126; }
fi
[ "$timeout_arg" -le "$max_timeout_value" ] || { append_rejection_locked "$state_file" "$assignment_id" 'assignment timeout exceeds maximum' "$(jq -cn --argjson timeout_seconds "$timeout_arg" --argjson max_timeout_seconds "$max_timeout_value" '{timeout_seconds:$timeout_seconds,max_timeout_seconds:$max_timeout_seconds}')"; release_lock "$lock"; fail 'dispatch rejected: timeout exceeds maximum' 126; }
used_resources=$(jq '[.assignments[].budget.resource_units] | add // 0' "$state_file")
[ $((used_resources + resources_arg)) -le "$max_resources_value" ] || { append_rejection_locked "$state_file" "$assignment_id" 'maximum resource budget exceeded' "$(jq -cn --argjson resource_units "$resources_arg" --argjson used_resource_units "$used_resources" --argjson max_resource_units "$max_resources_value" '{resource_units:$resource_units,used_resource_units:$used_resource_units,max_resource_units:$max_resource_units}')"; release_lock "$lock"; fail 'dispatch rejected: resource budget exceeded' 126; }
duplicate_count=$(jq --arg id "$assignment_id" '[.assignments[] | select(.assignment_id == $id)] | length' "$state_file")
[ "$duplicate_count" -eq 0 ] || { release_lock "$lock"; fail "assignment id already exists: $assignment_id"; }

source_repo_abs=$(canonical_path "$source_repo")
output_abs=$(canonical_path "$output_path")
error_abs=$(canonical_path "$error_path")
[ -n "$source_repo_abs" ] && source_repo="$source_repo_abs"
output_path="$output_abs"
error_path="$error_abs"
if [ -n "$workspace_dir" ]; then workspace_dir=$(canonical_path "$workspace_dir"); fi
if [ -n "$workspace_manifest" ]; then workspace_manifest=$(canonical_path "$workspace_manifest"); fi
manifest_abs='null'; [ -n "$workspace_manifest" ] && manifest_abs=$(printf '%s' "$(canonical_path "$workspace_manifest")" | jq -R .)
workspace_abs='null'; [ -n "$workspace_dir" ] && workspace_abs=$(printf '%s' "$(canonical_path "$workspace_dir")" | jq -R .)
owned_json=$(printf '%s\n' "${owned_paths[@]}" | jq -R . | jq -s .)
frozen_json=$(if [ "${#frozen_paths[@]}" -gt 0 ]; then printf '%s\n' "${frozen_paths[@]}" | jq -R . | jq -s .; else printf '[]'; fi)
jq --arg id "$assignment_id" --arg parent "$parent_id" --arg role_value "$role" --arg repo "$source_repo_abs" --arg base "$baseline" \
   --arg out "$output_abs" --arg err "$error_abs" --argjson manifest "$manifest_abs" --argjson workspace "$workspace_abs" \
   --argjson owned "$owned_json" --argjson frozen "$frozen_json" --argjson depth "$depth" --argjson timeout "$timeout_arg" --argjson resources "$resources_arg" --arg created "$(now)" \
   '.assignments += [{assignment_id:$id,parent_assignment_id:(if $parent == "" then null else $parent end),child_assignment_ids:[],depth:$depth,budget:{timeout_seconds:$timeout,resource_units:$resources},owned_paths:$owned,frozen_paths:$frozen,role:$role_value,lifecycle_state:"created",source_repo:$repo,baseline:$base,output_path:$out,error_path:$err,workspace_manifest:$manifest,workspace_dir:$workspace,created_at:$created,started_at:null,ended_at:null,exit_code:null}] |
    if $parent == "" then . else .assignments |= map(if .assignment_id == $parent then .child_assignment_ids += [$id] else . end) end' "$state_file" >"${state_file}.$$.tmp"
mv -f "${state_file}.$$.tmp" "$state_file"
release_lock "$lock"

mark_assignment_failed() {
  local assignment="$1" exit_code="$2" failure_message="$3" lock
  lock=$(acquire_lock "$state_file")
  jq --arg id "$assignment" --arg ended "$(now)" --arg message "$failure_message" --argjson exit_code "$exit_code" \
    '(.assignments[] | select(.assignment_id == $id)) |= (.lifecycle_state="failed" | .ended_at=$ended | .exit_code=$exit_code | .failure=$message)' \
    "$state_file" >"${state_file}.$$.tmp"
  mv -f "${state_file}.$$.tmp" "$state_file"
  release_lock "$lock"
}

workspace_args=(create --source-repo "$source_repo" --task-id "$assignment_id" --baseline "$baseline")
for path in "${owned_paths[@]}"; do workspace_args+=(--owned "$path"); done
for path in "${frozen_paths[@]}"; do workspace_args+=(--frozen "$path"); done
[ -n "$workspace_manifest" ] && workspace_args+=(--manifest "$workspace_manifest")
[ -n "$workspace_dir" ] && workspace_args+=(--workspace-dir "$workspace_dir")
set +e
workspace_output=$("$WORKSPACE_HELPER" "${workspace_args[@]}" 2>&1)
workspace_exit=$?
set -e
if [ "$workspace_exit" -ne 0 ]; then
  mark_assignment_failed "$assignment_id" 1 "worktree creation failed: $workspace_output"
  fail "failed to create worker worktree: $workspace_output" 1
fi
if [ -n "$workspace_dir" ]; then
  workspace_path=$(canonical_path "$workspace_dir")
else
  if [ ! -f "$workspace_manifest" ]; then
    mark_assignment_failed "$assignment_id" 1 'workspace helper did not produce a manifest for the assigned worker'
    fail 'workspace helper did not produce a manifest for the assigned worker' 1
  fi
  workspace_path=$(jq -r '.workspace_dir' "$workspace_manifest")
fi
if [ ! -d "$workspace_path" ]; then
  mark_assignment_failed "$assignment_id" 1 "assigned worker worktree does not exist: $workspace_path"
  fail "assigned worker worktree does not exist: $workspace_path" 1
fi

lock=$(acquire_lock "$state_file")
jq --arg id "$assignment_id" --arg workspace "$workspace_path" --arg manifest "$workspace_manifest" --arg started "$(now)" \
  '(.assignments[] | select(.assignment_id == $id)) |= (.workspace_dir=$workspace | .workspace_manifest=(if $manifest == "" then .workspace_manifest else $manifest end) | .lifecycle_state="running" | .started_at=$started)' "$state_file" >"${state_file}.$$.tmp"
mv -f "${state_file}.$$.tmp" "$state_file"
release_lock "$lock"

set +e
(cd "$workspace_path" && "$LAUNCHER" --role "$role" --timeout-seconds "$timeout_arg" --output "$output_path" --error "$error_path" -- "${worker_args[@]}")
worker_exit=$?
set -e

lock=$(acquire_lock "$state_file")
jq --arg id "$assignment_id" --arg ended "$(now)" --argjson exit_code "$worker_exit" \
  '(.assignments[] | select(.assignment_id == $id)) |= (.lifecycle_state=(if $exit_code == 0 then "completed" else "failed" end) | .ended_at=$ended | .exit_code=$exit_code)' "$state_file" >"${state_file}.$$.tmp"
mv -f "${state_file}.$$.tmp" "$state_file"
release_lock "$lock"

jq -c --arg id "$assignment_id" '.assignments[] | select(.assignment_id == $id)' "$state_file"
exit "$worker_exit"
