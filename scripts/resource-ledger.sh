#!/usr/bin/env bash
# scripts/resource-ledger.sh
# Durable, orchestrator-owned ownership ledger for worker resources.

set -euo pipefail

LEDGER_MARKER='offload-resource-ledger-v1'

die() { printf 'Error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { cat >&2 <<'EOF'
Usage:
  resource-ledger.sh init --ledger PATH
  resource-ledger.sh register --ledger PATH --assignment-id ID --parent-id ID --resource-type TYPE --owner-marker NAME=VALUE (--path PATH | --process-id PID) [--parent-path PATH] [--resource-id ID] [--state STATE]
  resource-ledger.sh update --ledger PATH --resource-id ID --state STATE [--allow-dirty true|false] [--error MESSAGE]
  resource-ledger.sh cleanup --ledger PATH --resource-id ID
  resource-ledger.sh reconcile --ledger PATH [--source-repo PATH ...]
EOF
}
need_jq() { command -v jq >/dev/null 2>&1 || die 'jq is required by resource-ledger.sh'; }
canon() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$PWD" "$(basename "$1")") || die "cannot resolve path: $1"; }
now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
atomic_write() { local path=$1; local tmp="${path}.tmp.$$.$RANDOM"; mkdir -p "$(dirname "$path")"; cat >"$tmp"; mv -f -- "$tmp" "$path"; }
init_ledger() { local path; path=$(canon "$1"); if [[ -f $path ]]; then jq -e --arg m "$LEDGER_MARKER" '.schema_version == 1 and .marker == $m' "$path" >/dev/null || die "invalid resource ledger: $path"; else atomic_write "$path" <<EOF
{"schema_version":1,"marker":"$LEDGER_MARKER","ledger_id":"$(date +%s)-$$-$RANDOM","created_at":"$(now)","updated_at":"$(now)","resources":[]}
EOF
fi; }
getopt_value() { local key=$1; shift; local a; while (($#)); do a=$1; shift; if [[ $a == "$key" ]]; then (($#)) || die "$key requires a value"; printf '%s' "$1"; return; elif [[ $a == "$key="* ]]; then printf '%s' "${a#*=}"; return; fi; done; return 1; }
required() { local key=$1; shift; local value; value=$(getopt_value "$key" "$@") || die "$key is required"; [[ -n $value ]] || die "$key is required"; printf '%s' "$value"; }
within() { local child=$1 parent=$2; [[ $child == "$parent" || $child == "$parent"/* ]]; }
marker_parts() { [[ $1 == *=* ]] || die '--owner-marker must be NAME=VALUE'; printf '%s\n%s\n' "${1%%=*}" "${1#*=}"; }
resource_filter() { jq -e --arg id "$2" '.resources[] | select(.resource_id == $id)' "$1" >/dev/null 2>&1; }

cmd_register() {
  local ledger assignment parent type markerRaw resourcePath processId parentPath resourceId state markerName markerValue
  ledger=$(canon "$(required --ledger "$@")"); assignment=$(required --assignment-id "$@"); parent=$(required --parent-id "$@"); type=$(required --resource-type "$@"); markerRaw=$(required --owner-marker "$@")
  resourcePath=$(getopt_value --path "$@" || true); processId=$(getopt_value --process-id "$@" || true); parentPath=$(getopt_value --parent-path "$@" || true); resourceId=$(getopt_value --resource-id "$@" || true); state=$(getopt_value --state "$@" || printf registered)
  [[ -n $resourcePath || -n $processId ]] || die 'one of --path or --process-id is required'
  [[ -z $resourcePath || -z $processId ]] || die '--path and --process-id cannot be combined'
  [[ -z $resourcePath || $resourcePath = /* || $resourcePath = [A-Za-z]:* ]] || die '--path must be absolute'
  [[ -z $resourcePath ]] || { resourcePath=$(canon "$resourcePath"); within "$ledger" "$resourcePath" && die 'ledger must be outside the resource path'; }
  [[ $state =~ ^(registered|active|completed|failed|timed_out|cancelled|quota_handoff|cleanup_pending|removed|retained|unknown|dirty|unmerged|ambiguous)$ ]] || die "invalid resource state: $state"
  read -r markerName markerValue < <(marker_parts "$markerRaw" | paste -sd ' ' -)
  [[ -z ${parentPath:-} ]] || parentPath=$(canon "$parentPath")
  init_ledger "$ledger"; resourceId=${resourceId:-$type:$(date +%s%N)}
  local startTime=''; [[ -n $processId ]] && startTime=$(ps -o lstart= -p "$processId" 2>/dev/null | sed 's/^ *//' || true)
  local record; record=$(jq -n --arg id "$resourceId" --arg a "$assignment" --arg p "$parent" --arg pp "${parentPath:-}" --arg t "$type" --arg path "${resourcePath:-}" --arg pn "${processId:-}" --arg st "$startTime" --arg mn "$markerName" --arg mv "$markerValue" --arg state "$state" --arg now "$(now)" '{resource_id:$id,assignment_id:$a,parent_id:$p,parent_path:(if $pp=="" then null else $pp end),resource_type:$t,path:(if $path=="" then null else $path end),process_identity:(if $pn=="" then null else {pid:($pn|tonumber),start_time:(if $st=="" then null else $st end)} end),owner_marker:{name:$mn,value:$mv},state:$state,allow_dirty:false,created_at:$now,updated_at:$now,cleanup_attempts:0,last_error:null}')
  jq --arg id "$resourceId" --argjson record "$record" '.resources = ((.resources // []) | map(select(.resource_id != $id)) + [$record]) | .updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' "$ledger" | atomic_write "$ledger"
  printf '%s\n' "$record"
}

cmd_update() {
  local ledger id state allowDirty error; ledger=$(canon "$(required --ledger "$@")"); id=$(required --resource-id "$@"); state=$(required --state "$@"); allowDirty=$(getopt_value --allow-dirty "$@" || true); error=$(getopt_value --error "$@" || true)
  [[ $state =~ ^(registered|active|completed|failed|timed_out|cancelled|quota_handoff|cleanup_pending|removed|retained|unknown|dirty|unmerged|ambiguous)$ ]] || die "invalid resource state: $state"; init_ledger "$ledger"; resource_filter "$ledger" "$id" || die "resource not found in ledger: $id"
  jq --arg id "$id" --arg state "$state" --arg allow "$allowDirty" --arg error "$error" '(.resources[] | select(.resource_id == $id)) |= (.state=$state | if $allow=="" then . else .allow_dirty=($allow=="true") end | if $error=="" then . else .last_error=$error end | .updated_at=(now|strftime("%Y-%m-%dT%H:%M:%SZ"))) | .updated_at=(now|strftime("%Y-%m-%dT%H:%M:%SZ"))' "$ledger" | atomic_write "$ledger"; jq -c --arg id "$id" '.resources[]|select(.resource_id==$id)' "$ledger"
}

process_alive() { local pid=$1 state; kill -0 "$pid" 2>/dev/null || return 1; state=$(ps -o stat= -p "$pid" 2>/dev/null | sed 's/^ *//'); [[ $state != Z* ]]; }
process_identity_matches() { local pid=$1 expected=$2 actual; [[ -z $expected ]] && return 0; actual=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//' || true); [[ -n $actual && $actual == "$expected" ]]; }
stop_process() { local pid=$1 expected=${2:-}; [[ $pid -ne $$ ]] || return 1; if process_alive "$pid"; then process_identity_matches "$pid" "$expected" || return 1; kill -TERM "$pid" 2>/dev/null || return 1; for _ in {1..100}; do process_alive "$pid" || return 0; sleep 0.1; done; kill -KILL "$pid" 2>/dev/null || true; ! process_alive "$pid"; else return 0; fi; }
registered_worktree() { git -C "$1" worktree list --porcelain 2>/dev/null | awk -v p="$2" '$1=="worktree" && substr($0,10)==p {found=1} END {exit found?0:1}'; }
protected_path() { local p=$1; [[ $p == / || $p == "$PWD" || $p == "$HOME" || $p == "$(canon /tmp)" ]]; }

classify_cleanup() {
  local ledger=$1 id=$2; local record path parent markerName markerValue pid processStart result dirty unmerged state
  record=$(jq -c --arg id "$id" '.resources[]|select(.resource_id==$id)' "$ledger") || die "resource not found in ledger: $id"
  state=$(jq -r '.state' <<<"$record"); if [[ $state == removed || $state == retained || $state == unknown || $state == dirty || $state == unmerged || $state == ambiguous ]]; then jq -n --arg id "$id" --arg s "$state" '{resource_id:$id,state:$s,removed:false,retained:($s!="removed"),reason:"already-classified"}'; return; fi
  pid=$(jq -r '.process_identity.pid // empty' <<<"$record"); processStart=$(jq -r '.process_identity.start_time // empty' <<<"$record")
  if [[ -n $pid ]] && process_alive "$pid" && ! process_identity_matches "$pid" "$processStart"; then result=$(jq -n --arg id "$id" '{resource_id:$id,state:"unknown",removed:false,retained:true,reason:"process identity no longer matches"}'); printf '%s\n' "$result"; return; fi
  if [[ -n $pid ]] && ! stop_process "$pid" "$processStart"; then result=$(jq -n --arg id "$id" '{resource_id:$id,state:"retained",removed:false,retained:true,reason:"owned process could not be terminated"}'); printf '%s\n' "$result"; return; fi
  path=$(jq -r '.path // empty' <<<"$record"); if [[ -z $path || ! -e $path ]]; then jq --arg id "$id" '.resources[]|select(.resource_id==$id)|.state="removed"' "$ledger" >/dev/null; jq -n --arg id "$id" '{resource_id:$id,state:"removed",removed:true,retained:false,reason:"path already absent"}'; return; fi
  markerName=$(jq -r '.owner_marker.name // empty' <<<"$record"); markerValue=$(jq -r '.owner_marker.value // empty' <<<"$record"); parent=$(jq -r '.parent_path // empty' <<<"$record")
  if protected_path "$path" || [[ -z $markerName || ! -f "$path/$markerName" || $(tr -d '\r\n' <"$path/$markerName") != "$markerValue" ]] || [[ -L $path ]]; then jq -n --arg id "$id" '{resource_id:$id,state:"unknown",removed:false,retained:true,reason:"protected, unowned, or reparse path"}'; return; fi
  parent=$(canon "$parent")
  if [[ $(jq -r '.resource_type' <<<"$record") == git-worktree ]]; then
    registered_worktree "$parent" "$path" || { jq -n --arg id "$id" '{resource_id:$id,state:"ambiguous",removed:false,retained:true,reason:"worktree is not registered with its parent repository"}'; return; }
    if [[ $(jq -r '.allow_dirty' <<<"$record") != true ]]; then dirty=$(git -C "$path" status --porcelain 2>/dev/null || true); unmerged=$(git -C "$path" ls-files -u 2>/dev/null || true); if [[ -n $dirty ]]; then jq -n --arg id "$id" '{resource_id:$id,state:"dirty",removed:false,retained:true,reason:"worktree is dirty"}'; return; fi; if [[ -n $unmerged || -f "$path/.git/MERGE_HEAD" ]]; then jq -n --arg id "$id" '{resource_id:$id,state:"unmerged",removed:false,retained:true,reason:"worktree has an unmerged state"}'; return; fi; fi
    git -C "$parent" worktree remove --force "$path" >/dev/null 2>&1 || { jq -n --arg id "$id" '{resource_id:$id,state:"retained",removed:false,retained:true,reason:"git worktree removal failed"}'; return; }; git -C "$parent" worktree prune >/dev/null 2>&1 || true
  else [[ -d $path ]] || { jq -n --arg id "$id" '{resource_id:$id,state:"ambiguous",removed:false,retained:true,reason:"resource is not a directory"}'; return; }; [[ $(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true) != "$path" ]] || { jq -n --arg id "$id" '{resource_id:$id,state:"ambiguous",removed:false,retained:true,reason:"resource is a git checkout"}'; return; }; find -P "$path" -type l -print -quit | grep -q . && { jq -n --arg id "$id" '{resource_id:$id,state:"ambiguous",removed:false,retained:true,reason:"resource contains a reparse or symlink"}'; return; }; rm -rf -- "$path"; fi
  jq -n --arg id "$id" '{resource_id:$id,state:"removed",removed:true,retained:false,reason:null}'
}

cmd_cleanup() { local ledger id result nextState reason; ledger=$(canon "$(required --ledger "$@")"); id=$(required --resource-id "$@"); init_ledger "$ledger"; jq --arg id "$id" '(.resources[]|select(.resource_id==$id)).cleanup_attempts += 1' "$ledger" | atomic_write "$ledger"; result=$(classify_cleanup "$ledger" "$id"); nextState=$(jq -r '.state' <<<"$result"); reason=$(jq -r '.reason // empty' <<<"$result"); jq --arg id "$id" --arg state "$nextState" --arg reason "$reason" '(.resources[]|select(.resource_id==$id)) |= (.state=$state|.last_error=(if $reason=="" then null else $reason end)|.updated_at=(now|strftime("%Y-%m-%dT%H:%M:%SZ"))) | .updated_at=(now|strftime("%Y-%m-%dT%H:%M:%SZ"))' "$ledger" | atomic_write "$ledger"; printf '%s\n' "$result"; }

cmd_reconcile() { local ledger repo line path known id; ledger=$(canon "$(required --ledger "$@")"); init_ledger "$ledger"; local repos=(); while (($#)); do case "$1" in --source-repo) shift; (($#)) || die '--source-repo requires a path'; repos+=("$1");; --source-repo=*) repos+=("${1#*=}");; esac; shift; done; for repo in "${repos[@]}"; do repo=$(canon "$repo"); while IFS= read -r line; do [[ $line == worktree\ * ]] || continue; path=${line#worktree }; [[ $(canon "$path") == "$repo" ]] && continue; known=$(jq -e --arg p "$(canon "$path")" '.resources[]|select(.path==$p)' "$ledger" >/dev/null 2>&1; echo $?); if [[ $known -ne 0 ]]; then jq --arg path "$(canon "$path")" --arg repo "$repo" '.resources += [{resource_id:("unknown-worktree:" + (now|tostring)),assignment_id:"unknown",parent_id:$repo,parent_path:$repo,resource_type:"git-worktree",path:$path,process_identity:null,owner_marker:{name:"",value:""},state:"unknown",allow_dirty:false,created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),updated_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),cleanup_attempts:0,last_error:"worktree was not present in the ownership ledger"}]' "$ledger" | atomic_write "$ledger"; fi; done < <(git -C "$repo" worktree list --porcelain 2>/dev/null); done; for id in $(jq -r '.resources[]|select(.state|IN("registered","active","failed","timed_out","cancelled","quota_handoff","cleanup_pending","completed"))|select(.resource_type=="worker-process")|.resource_id' "$ledger"); do cmd_cleanup --ledger "$ledger" --resource-id "$id"; done; for id in $(jq -r '.resources[]|select(.state|IN("registered","active","failed","timed_out","cancelled","quota_handoff","cleanup_pending","completed"))|select(.resource_type!="worker-process")|.resource_id' "$ledger"); do cmd_cleanup --ledger "$ledger" --resource-id "$id"; done; }

need_jq; (($# > 0)) || { usage; exit 1; }; command=$1; shift; case "$command" in init) ledger=$(canon "$(required --ledger "$@")"); init_ledger "$ledger"; jq -n --arg l "$ledger" '{ledger:$l,state:"ready"}';; register) cmd_register "$@";; update) cmd_update "$@";; cleanup) cmd_cleanup "$@";; reconcile) cmd_reconcile "$@";; -h|--help) usage;; *) die "unrecognized command: $command";; esac
