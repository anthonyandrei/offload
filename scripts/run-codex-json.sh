#!/usr/bin/env bash
set -euo pipefail
fail() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() {
  printf 'Usage: %s capabilities --output FILE [--error FILE] [--codex PATH]\n' "$0" >&2
  printf '       %s run --assignment FILE --output FILE --error FILE [--codex PATH] [--cancel-file FILE]\n' "$0" >&2
}

run_assignment() {
  local assignment_path="$1" output_path="$2" error_path="$3" codex_path="$4" cancel_file="$5"
  local assignment worktree timeout selection raw_output last_message schema_file ledger marker help_probe help_exit=0
  assignment=$(cat "$assignment_path")
  jq -e 'type == "object" and .schema_version == 1 and (.assignment_id | type == "string" and test("^[A-Za-z0-9._-]+$")) and ((.depth // 0) >= 0) and (((.attempt // 1) == 1) or ((.attempt // 1) == 2))' <<<"$assignment" >/dev/null || fail 'assignment does not satisfy the adapter contract' 1
  worktree=$(jq -r '.worktree' <<<"$assignment")
  [ -d "$worktree" ] || fail "assignment worktree does not exist: $worktree"
  timeout=$(jq -r '.timeout_seconds // 30' <<<"$assignment")
  marker="offload-assignment:$(jq -r '.assignment_id' <<<"$assignment")"
  ensure_parent "$error_path"; : >"$error_path"
  if ! valid_catalog; then
    write_json "$output_path" "$(jq -cn --arg id "$(jq -r '.assignment_id' <<<"$assignment")" --arg worktree "$worktree" --arg error "$(full_path "$error_path")" '{schema_version:1,status:"unsupported",lifecycle:"failed",assignment_id:$id,vendor:"codex",adapter:"run-codex-json",failure:{kind:"unsupported-capability",reason:"host does not expose a model catalog"},resources:{process:null,worktree:$worktree,artifacts:[$error]},artifacts:[$error]}')"
    return 1
  fi
  help_probe=$("$codex_path" --help 2>"$error_path") || help_exit="$?"
  if [ "$help_exit" -ne 0 ] || [[ "$help_probe" != *--json* ]] || [[ "$help_probe" != *--output-schema* ]] || [[ "$help_probe" != *--output-last-message* ]]; then
    local help_reason='host lacks required structured-output flags'
    [ "$help_exit" -eq 0 ] || help_reason='Codex capability probe failed'
    write_json "$output_path" "$(jq -cn --arg id "$(jq -r '.assignment_id' <<<"$assignment")" --arg worktree "$worktree" --arg error "$(full_path "$error_path")" --arg reason "$help_reason" '{schema_version:1,status:"unsupported",lifecycle:"failed",assignment_id:$id,vendor:"codex",adapter:"run-codex-json",failure:{kind:"unsupported-capability",reason:$reason},resources:{process:null,worktree:$worktree,artifacts:[$error]},artifacts:[$error]}')"
    return 1
  fi
  selection=$(select_model "$assignment")
  raw_output="$output_path.raw.jsonl"
  last_message="$output_path.last-message.json"
  schema_file="$output_path.output-schema.json"
  ledger=$(jq -r '.resource_ledger // empty' <<<"$assignment")
  [ -n "$ledger" ] || ledger="$output_path.resource-ledger.jsonl"
  write_json "$schema_file" '{"type":"object","additionalProperties":true}'
  ensure_parent "$raw_output"; : >"$raw_output"; : >"$error_path"
  ledger_record "$ledger" "$assignment" worktree "$worktree" "$marker" running
  ledger_record "$ledger" "$assignment" artifact "$(full_path "$raw_output")" "$marker" running
  ledger_record "$ledger" "$assignment" artifact "$(full_path "$error_path")" "$marker" running
  ledger_record "$ledger" "$assignment" artifact "$(full_path "$last_message")" "$marker" running
  ledger_record "$ledger" "$assignment" artifact "$(full_path "$schema_file")" "$marker" running
  local model_id prompt resume args
  model_id=$(jq -r '.model_id' <<<"$selection")
  prompt=$(jq -r '.prompt' <<<"$assignment")
  resume=$(jq -r '.resume_session_id // empty' <<<"$assignment")
  if [ -n "$resume" ]; then
    args=(-C "$worktree" --sandbox workspace-write --ask-for-approval never exec resume "$resume" --json --ephemeral --output-schema "$(full_path "$schema_file")" --output-last-message "$(full_path "$last_message")" --model "$model_id" -- "$prompt")
  else
    args=(exec --json --ephemeral --cd "$worktree" --sandbox workspace-write --ask-for-approval never --output-schema "$(full_path "$schema_file")" --output-last-message "$(full_path "$last_message")" --model "$model_id" -- "$prompt")
  fi

  local process_reason=completed process_exit=0 start now worker_pid
  start=$(date +%s)
  set +e
  (cd "$worktree" && "$codex_path" "${args[@]}") >"$raw_output" 2>"$error_path" &
  worker_pid="$!"
  set -e
  while kill -0 "$worker_pid" >/dev/null 2>&1; do
    if [ -n "$cancel_file" ] && [ -f "$cancel_file" ]; then
      process_reason=canceled; kill "$worker_pid" >/dev/null 2>&1 || true; break
    fi
    now=$(date +%s)
    if [ "$timeout" -gt 0 ] && [ $((now - start)) -ge "$timeout" ]; then
      process_reason=timeout; kill "$worker_pid" >/dev/null 2>&1 || true; break
    fi
    sleep 0.05
  done
  wait "$worker_pid" || process_exit="$?"
  ledger_record "$ledger" "$assignment" process "pid:$worker_pid" "$marker" "$process_reason"
  local base assignment_id parent_json attempt raw_path error_path_abs last_path schema_path
  assignment_id=$(jq -r '.assignment_id' <<<"$assignment")
  parent_json=$(jq -c '.parent_assignment_id // null' <<<"$assignment")
  attempt=$(jq -r '.attempt // 1' <<<"$assignment")
  raw_path=$(full_path "$raw_output"); error_path_abs=$(full_path "$error_path"); last_path=$(full_path "$last_message"); schema_path=$(full_path "$schema_file")
  base=$(jq -cn --arg id "$assignment_id" --argjson parent "$parent_json" --argjson selection "$selection" --argjson pid "$worker_pid" --argjson exit "$process_exit" --argjson attempt "$attempt" --arg worktree "$worktree" --arg raw "$raw_path" --arg error "$error_path_abs" --arg last "$last_path" --arg schema "$schema_path" '{schema_version:1,assignment_id:$id,parent_assignment_id:$parent,vendor:"codex",adapter:"run-codex-json",attempt:$attempt,lifecycle:"running",model_selection:$selection,process:{pid:$pid,exit_code:$exit},resources:{process:("pid:" + ($pid|tostring)),worktree:$worktree,artifacts:[$raw,$error,$last,$schema]},artifacts:[$raw,$error,$last,$schema],verification:{scope_check:"not-run",final_gate:"not-run"}}')
  if [ "$process_reason" = canceled ]; then
    write_json "$output_path" "$(jq '.status="canceled" | .lifecycle="canceled" | .failure={kind:"canceled",reason:"cancel file requested termination"}' <<<"$base")"; return 1
  fi
  if [ "$process_reason" = timeout ]; then
    write_json "$output_path" "$(jq '.status="failed" | .lifecycle="failed" | .failure={kind:"timeout",reason:"assignment timeout exceeded"}' <<<"$base")"; return 1
  fi
  if grep -Eiq 'quota|rate.?limit' "$raw_output" "$error_path"; then
    write_json "$output_path" "$(jq '.status="quota-handoff" | .lifecycle="quota-handoff" | .failure={kind:"quota",reason:"Codex reported quota or rate limit exhaustion"}' <<<"$base")"; return 1
  fi
  if [ ! -f "$last_message" ] || ! jq -e 'type == "object" and has("structured_output")' "$last_message" >/dev/null 2>&1; then
    write_json "$output_path" "$(jq '.status="failed" | .lifecycle="failed" | .failure={kind:"malformed-output",reason:"Codex did not produce a valid structured-output artifact"}' <<<"$base")"; return 1
  fi

  local scope_exit=0 gate_exit=0
  set +e
  run_command_array "$(jq -c '.scope_check // []' <<<"$assignment")" "$worktree"
  scope_exit="$?"
  set -e
  if [ "$scope_exit" -eq 0 ]; then base=$(jq '.verification.scope_check="passed"' <<<"$base"); else base=$(jq '.verification.scope_check="failed"' <<<"$base"); fi
  if [ "$scope_exit" -ne 0 ]; then
    write_json "$output_path" "$(jq --argjson code "$scope_exit" '.status="scope-failure" | .lifecycle="failed" | .failure={kind:"execution-scope",reason:"execution scope check failed",exit_code:$code}' <<<"$base")"; return 1
  fi
  set +e
  run_command_array "$(jq -c '.final_gate // []' <<<"$assignment")" "$worktree"
  gate_exit="$?"
  set -e
  if [ "$gate_exit" -eq 0 ]; then base=$(jq '.verification.final_gate="passed"' <<<"$base"); else base=$(jq '.verification.final_gate="failed"' <<<"$base"); fi
  if [ "$gate_exit" -ne 0 ]; then
    write_json "$output_path" "$(jq --argjson code "$gate_exit" '.status="failed" | .lifecycle="failed" | .failure={kind:"final-gate",reason:"final gate failed",exit_code:$code}' <<<"$base")"; return 1
  fi
  write_json "$output_path" "$(jq --slurpfile worker "$last_message" '.status="completed" | .lifecycle="completed" | .structured_output=$worker[0].structured_output | if (.structured_output | has("child_assignment_request")) then .orchestrator_requests=[.structured_output.child_assignment_request] else . end' <<<"$base")"
}

run_command_array() {
  local command_json="$1" worktree="$2" arg
  local command_args=()
  while IFS= read -r arg; do command_args+=("$arg"); done < <(jq -r '.[] | tostring' <<<"$command_json")
  [ "${#command_args[@]}" -gt 0 ] || return 2
  (cd "$worktree" && "${command_args[@]}")
}


ledger_record() {
  local ledger="$1" assignment="$2" type="$3" identity="$4" marker="$5" state="$6"
  ensure_parent "$ledger"
  jq -cn --arg id "$(jq -r '.assignment_id' <<<"$assignment")" --argjson parent "$(jq -c '.parent_assignment_id // null' <<<"$assignment")" --arg type "$type" --arg identity "$identity" --arg marker "$marker" --arg state "$state" '{schema_version:1,assignment_id:$id,parent_assignment_id:$parent,resource_type:$type,identity:$identity,owner_marker:$marker,state:$state,timestamp:(now | todateiso8601)}' >>"$ledger"
}


select_model() {
  local assignment="$1" catalog pref effort pinned
  catalog=$(catalog_json) || fail 'host does not expose a model catalog' 1
  pref=$(jq -r '.preference // empty' <<<"$assignment")
  effort=$(jq -r '.effort // empty' <<<"$assignment")
  pinned=$(jq -r '.model_id // .model_selection.model_id // empty' <<<"$assignment")
  jq -e --arg p "$pref" --arg e "$effort" --arg m "$pinned" '($p | IN("fast","balanced","deep")) and ([.models[] | select((if $m != "" then .id == $m else .preference == $p end) and ($e == "" or ((.efforts // []) | index($e))))] | length > 0)' <<<"$catalog" >/dev/null || fail 'no available Codex model satisfies assignment preference and effort' 1
  jq -c --arg p "$pref" --arg e "$effort" --arg m "$pinned" '([.models[] | select(if $m != "" then .id == $m else .preference == $p end) | select($e == "" or ((.efforts // []) | index($e)))] | sort_by(.id) | .[0]) as $model | {vendor:"codex",adapter:"run-codex-json",model_id:$model.id,family_hint:($model.family_hint // null),preference:$p,effort:(if $e != "" then $e else ($model.efforts[0] // null) end),catalog_revision:(.revision // null),reason:(if $m != "" then "pinned assignment model" else "first deterministic catalog match for " + $p end)}' <<<"$catalog"
}

full_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")" ;;
  esac
}
ensure_parent() { mkdir -p "$(dirname "$1")"; }
resolve_codex() {
  if [ -n "$1" ] && [ -x "$1" ]; then full_path "$1"
  elif [ -n "$1" ] && command -v "$1" >/dev/null 2>&1; then command -v "$1"
  elif [ -z "$1" ] && command -v codex >/dev/null 2>&1; then command -v codex
  else fail 'Codex executable was not found or is not executable' 1
  fi
}
catalog_json() {
  [ -n "${CODEX_MODEL_CATALOG:-}" ] || return 1
  if [ -f "$CODEX_MODEL_CATALOG" ]; then cat "$CODEX_MODEL_CATALOG"; else printf '%s\n' "$CODEX_MODEL_CATALOG"; fi
}
valid_catalog() {
  catalog_json 2>/dev/null | jq -e 'type == "object" and (.models | type == "array") and (.models | length > 0)' >/dev/null 2>&1
}
write_json() { ensure_parent "$1"; printf '%s\n' "$2" >"$1"; }

capabilities() {
  local output="$1" error="$2" codex="$3" help_file error_file probe_exit=0 help_text catalog='' models='[]' efforts='[]' available=false reason document
  help_file=$(mktemp "${TMPDIR:-/tmp}/offload-codex-help.XXXXXX")
  error_file=$(mktemp "${TMPDIR:-/tmp}/offload-codex-help-error.XXXXXX")
  "$codex" --help >"$help_file" 2>"$error_file" || probe_exit="$?"
  help_text=$(<"$help_file"); ensure_parent "$error"; cat "$error_file" >"$error"
  if valid_catalog; then
    catalog=$(catalog_json); models=$(jq -c '.models' <<<"$catalog"); efforts=$(jq -c '[.models[].efforts[]?] | unique' <<<"$catalog")
    available=true; reason='host-provided model catalog'
  else reason='host does not expose a model catalog'; fi
  if [ "$probe_exit" -ne 0 ] || [[ "$help_text" != *--json* ]] || [[ "$help_text" != *--output-schema* ]] || [[ "$help_text" != *--output-last-message* ]]; then
    [ "$probe_exit" -eq 0 ] && reason='host lacks required structured-output flags' || reason='Codex capability probe failed'
    document=$(jq -cn --arg reason "$reason" --arg error "$error" '{schema_version:1,vendor:"codex",adapter:"run-codex-json",supported_tools:["exec"],structured_output:{supported:false,reason:$reason},model_availability:{available:false,reason:$reason,revision:null,models:[]},effort_levels:[],process_identity:null,artifacts:[$error]}')
    write_json "$output" "$document"; rm -f "$help_file" "$error_file"; return 1
  fi
  document=$(jq -cn --argjson models "$models" --argjson efforts "$efforts" --arg reason "$reason" --arg revision "$(jq -r '.revision // empty' <<<"${catalog:-{}}")" --arg error "$error" --argjson available "$available" '{schema_version:1,vendor:"codex",adapter:"run-codex-json",supported_tools:["exec"],structured_output:{supported:true,format:"json",schema:"orchestrator-assignment-result"},model_availability:{available:$available,reason:$reason,revision:($revision // null),models:$models},effort_levels:$efforts,process_identity:null,artifacts:[$error]}')
  write_json "$output" "$document"; rm -f "$help_file" "$error_file"; [ "$available" = true ]
}

mode='' output_path='' error_path='' assignment_path='' codex_path='' cancel_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    capabilities|run) [ -z "$mode" ] || fail 'mode specified more than once'; mode="$1"; shift ;;
    --output) [ "$#" -ge 2 ] || fail '--output requires a path'; output_path="$2"; shift 2 ;;
    --error) [ "$#" -ge 2 ] || fail '--error requires a path'; error_path="$2"; shift 2 ;;
    --assignment) [ "$#" -ge 2 ] || fail '--assignment requires a path'; assignment_path="$2"; shift 2 ;;
    --codex) [ "$#" -ge 2 ] || fail '--codex requires a path'; codex_path="$2"; shift 2 ;;
    --cancel-file) [ "$#" -ge 2 ] || fail '--cancel-file requires a path'; cancel_file="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown option: $1" ;;
  esac
done
[ -n "$mode" ] || { usage; fail 'mode is required'; }
[ -n "$output_path" ] || { usage; fail '--output is required'; }
error_path="${error_path:-$output_path.err}"
codex_path=$(resolve_codex "$codex_path")
if [ "$mode" = capabilities ]; then
  capabilities "$output_path" "$error_path" "$codex_path"
else
  [ -n "$assignment_path" ] || fail '--assignment is required for run'
  run_assignment "$assignment_path" "$output_path" "$error_path" "$codex_path" "$cancel_file"
fi
