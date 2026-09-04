#!/usr/bin/env bash
# Validate the vendor-neutral worker adapter assignment/result boundary.

set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

if [ "$#" -ne 4 ] || [ "$1" != '--assignment' ] || [ "$3" != '--result' ]; then
  printf 'Usage: check-worker-adapter.sh --assignment FILE --result FILE\n' >&2
  exit 2
fi

assignment_path=$2
result_path=$4
[ -f "$assignment_path" ] || fail "assignment does not exist: $assignment_path"
[ -f "$result_path" ] || fail "result does not exist: $result_path"
jq -e 'type == "object"' "$assignment_path" >/dev/null 2>&1 || fail 'assignment is not a JSON object'
jq -e 'type == "object"' "$result_path" >/dev/null 2>&1 || fail 'result is not a JSON object'

contract_version=$(jq -r '.contract_version // empty' "$assignment_path")
[ "$contract_version" = '1' ] || fail 'assignment contract_version must be 1'
result_version=$(jq -r '.contract_version // empty' "$result_path")
[ "$result_version" = '1' ] || fail 'result contract_version must be 1'

assignment_id=$(jq -r '.assignment_id // empty' "$assignment_path")
[ -n "$assignment_id" ] || fail 'assignment.assignment_id must be a non-empty string'
[ "$(jq -r '.assignment_id // empty' "$result_path")" = "$assignment_id" ] || fail 'result assignment_id does not match assignment'
jq -e '(.request.prompt | type == "string" and length > 0)' "$assignment_path" >/dev/null || fail 'assignment.request.prompt must be a non-empty string'

jq -e '
  (.constraints | type == "object") and
  (.constraints.tools | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.constraints.permissions | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.constraints.owned_paths | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.constraints.frozen_paths | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.constraints.cleanup_resource_ids | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.constraints.worktree | type == "object" and (.id | type == "string" and length > 0) and (.path | type == "string" and length > 0)) and
  (.constraints.artifact_root | type == "string" and length > 0)
' "$assignment_path" >/dev/null || fail 'assignment constraints are incomplete or malformed'

jq -e '
  (.constraint_snapshot | type == "object") and
  (.constraint_snapshot.tools | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.constraint_snapshot.permissions | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.constraint_snapshot.owned_paths | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.constraint_snapshot.frozen_paths | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.constraint_snapshot.cleanup_resource_ids | type == "array" and all(.[]; type == "string" and length > 0)) and
  (.constraint_snapshot.worktree | type == "object" and (.id | type == "string" and length > 0) and (.path | type == "string" and length > 0)) and
  (.constraint_snapshot.artifact_root | type == "string" and length > 0)
' "$result_path" >/dev/null || fail 'result constraint_snapshot is incomplete or malformed'

jq -e -s '
  .[0] as $a | .[1] as $r |
  ($a.constraints) as $g | ($r.constraint_snapshot) as $u |
  (all($u.tools[]; . as $item | ($g.tools | index($item)) != null)) and
  (all($u.permissions[]; . as $item | ($g.permissions | index($item)) != null)) and
  (all($u.owned_paths[]; . as $item | any($g.owned_paths[]; . as $grant | $item == $grant or ($item | startswith($grant + "/"))))) and
  (all($u.frozen_paths[]; . as $item | any($g.frozen_paths[]; . as $grant | $item == $grant or ($item | startswith($grant + "/"))))) and
  (all($u.cleanup_resource_ids[]; . as $item | ($g.cleanup_resource_ids | index($item)) != null)) and
  ($u.worktree.id == $g.worktree.id) and ($u.worktree.path == $g.worktree.path) and
  ($u.artifact_root == $g.artifact_root)
' "$assignment_path" "$result_path" >/dev/null || fail 'result widens or changes assignment constraints'

status=$(jq -r '.status // empty' "$result_path")
case "$status" in succeeded|failed|cancelled|malformed) ;; *) fail "result.status '$status' is not supported" ;; esac

ownership_ids=$(jq -r '.ownership.resource_ids[]? // empty' "$result_path" | tr -d '\r')
jq -e '.ownership.resource_ids | type == "array" and all(.[]; type == "string" and length > 0)' "$result_path" >/dev/null || fail 'result.ownership.resource_ids is malformed'
jq -e '.resources | type == "array" and all(.[]; type == "object" and (.type | type == "string" and length > 0) and (.id | type == "string" and length > 0))' "$result_path" >/dev/null || fail 'result.resources is malformed'
worktree_path=$(jq -r '.constraints.worktree.path' "$assignment_path")
while IFS= read -r resource_id; do
  resource_id=${resource_id//$'\r'/}
  [ -z "$resource_id" ] && continue
  grep -Fqx "$resource_id" <<<"$ownership_ids" || fail "resource '$resource_id' is outside the adapter ownership record"
done < <(jq -r '.resources[].id' "$result_path")
while IFS= read -r resource_path; do
  resource_path=${resource_path//$'\r'/}
  [ -z "$resource_path" ] && continue
  case "$resource_path" in
    "$worktree_path"|"$worktree_path"/*) ;;
    *) fail "resource path is outside the worktree: $resource_path" ;;
  esac
done < <(jq -r '.resources[] | .path? // empty' "$result_path")

artifact_root=$(jq -r '.constraints.artifact_root' "$assignment_path")
while IFS= read -r artifact; do
  artifact=${artifact//$'\r'/}
  [ -n "$artifact" ] || fail 'result artifact path must be a non-empty string'
  case "$artifact" in "$artifact_root"|"$artifact_root"/*) ;; *) fail "artifact path is outside artifact_root: $artifact" ;; esac
  [ -f "$artifact" ] || fail "artifact does not exist: $artifact"
done < <(jq -r '.artifacts[] | .path // empty' "$result_path")
jq -e '.artifacts | type == "array" and all(.[]; type == "object" and (.path | type == "string" and length > 0) and (.kind | type == "string" and length > 0) and (.sha256 | type == "string" and length > 0) and (.verified == false))' "$result_path" >/dev/null || fail 'result.artifacts is malformed or claims adapter verification'

jq -e '(.model_selection | type == "object" and (.provider | type == "string" and length > 0) and (.model_id | type == "string" and length > 0) and (.selection_reason | type == "string" and length > 0)) and (.exit.code | type == "number" and floor == .) and (.publication.status == "unpublished")' "$result_path" >/dev/null || fail 'result model, exit, or publication metadata is malformed'

jq -cn --arg id "$assignment_id" '{contract_version: 1, status: "accepted-for-orchestrator-verification", assignment_id: $id}'
