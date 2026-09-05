#!/usr/bin/env bash
# Shared worker capacity reservations. The ledger stores no credentials.
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() { printf 'Usage: capacity-ledger.sh init|reserve|release|reconcile --ledger PATH [--selection PATH] [--reservation-id ID] [--state completed|cancelled|failed|recovered] [--reason TEXT]\n' >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
resolve_path() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$(pwd -P)" "$1" ;; esac; }

[ "$#" -ge 1 ] || { usage; exit 2; }
command_name="$1"; shift
ledger_path=''; selection_path=''; reservation_id=''; state=''; reason=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || fail "missing value for $1"
  case "$1" in
    --ledger) ledger_path="$2" ;;
    --selection) selection_path="$2" ;;
    --reservation-id) reservation_id="$2" ;;
    --state) state="$2" ;;
    --reason) reason="$2" ;;
    *) usage; fail "unknown option: $1" ;;
  esac
  shift 2
done
case "$command_name" in init|reserve|release|reconcile) ;; *) usage; exit 2 ;; esac
[ -n "$ledger_path" ] || fail '--ledger is required'
ledger_path="$(resolve_path "$ledger_path")"
mkdir -p "$(dirname "$ledger_path")"
lock_dir="$ledger_path.lockdir"
lock_acquired=false
for _attempt in $(seq 1 100); do
  if mkdir "$lock_dir" 2>/dev/null; then lock_acquired=true; break; fi
  sleep 0.05
done
$lock_acquired || fail "could not lock capacity ledger: $ledger_path" 4
cleanup_lock() { rmdir "$lock_dir" 2>/dev/null || true; }
trap cleanup_lock EXIT

if [ ! -f "$ledger_path" ]; then
  printf '{"schema_version":1,"ledger":"worker-capacity","created_at":"%s","updated_at":"%s","reservations":[]}\n' "$(now)" "$(now)" >"$ledger_path"
fi
jq -e '(.schema_version == 1 and .ledger == "worker-capacity")' "$ledger_path" >/dev/null 2>&1 || fail "unsupported capacity ledger: $ledger_path"

if [ "$command_name" = init ]; then jq . "$ledger_path"; exit 0; fi

if [ "$command_name" = reserve ]; then
  [ -n "$selection_path" ] || fail '--selection is required for reserve'
  jq -e '(.protocol_version == 2 and (.model_id|type == "string") and (.model_id|length > 0) and (.capacity_estimate.required_units|type == "number") and (.capacity_estimate.required_units > 0))' "$selection_path" >/dev/null 2>&1 || fail 'selection must use protocol 2 and include a positive capacity estimate' 4
  [ -n "$reservation_id" ] || reservation_id="reservation-$(date -u +%Y%m%d%H%M%S)-$$"
  jq -e --arg id "$reservation_id" 'any(.reservations[]?; .reservation_id == $id) | not' "$ledger_path" >/dev/null 2>&1 || fail "reservation already exists: $reservation_id" 4
  scopes_json=$(jq -c '[.reservation.scopes[]? | strings] | unique' "$selection_path")
  provider=$(jq -r '.provider // ""' "$selection_path"); model_id=$(jq -r '.model_id' "$selection_path"); units=$(jq -r '.capacity_estimate.required_units' "$selection_path")
  scope_count=$(jq 'length' <<<"$scopes_json")
  i=0
  while [ "$i" -lt "$scope_count" ]; do
    scope_id=$(jq -r --argjson i "$i" '.[$i]' <<<"$scopes_json")
    base_available=$(jq -r --arg scope "$scope_id" '([.preflight.usage.scopes[]? | select((.scope_id|tostring) == $scope) | ((.remaining_units // 0) - (.reserved_units // 0))] | first // -1)' "$selection_path")
    [ "$base_available" != -1 ] || fail "selection is missing capacity scope: $scope_id" 4
    already_reserved=$(jq -r --arg scope "$scope_id" --arg provider "$provider" --arg model "$model_id" '[.reservations[]? | select(.state == "active" and .provider == $provider and .model_id == $model and (.scopes // [] | index($scope) != null)) | .required_units] | add // 0' "$ledger_path")
    jq -n --argjson base "$base_available" --argjson used "$already_reserved" --argjson units "$units" '($base - $used) >= $units' | grep -qx true || fail "capacity reservation rejected for scope $scope_id" 4
    i=$((i + 1))
  done
  tmp="$ledger_path.tmp.$$"
  jq --arg id "$reservation_id" --arg provider "$provider" --arg model "$model_id" --argjson units "$units" --argjson scopes "$scopes_json" --arg adapter "$(jq -r '.adapter // ""' "$selection_path")" --arg adapter_revision "$(jq -r '.adapter_revision // ""' "$selection_path")" --arg catalog_revision "$(jq -r '.catalog_revision // ""' "$selection_path")" --arg policy_revision "$(jq -r '.policy_revision // ""' "$selection_path")" --arg usage_observed_at "$(jq -r '.usage_observed_at // ""' "$selection_path")" --argjson usage_uncertain "$(jq -c '.usage_uncertain // false' "$selection_path")" --arg now "$(now)" '.reservations += [{reservation_id:$id,state:"active",provider:$provider,model_id:$model,required_units:$units,scopes:$scopes,created_at:$now,updated_at:$now,released_at:null,release_reason:null,evidence:{adapter:$adapter,adapter_revision:$adapter_revision,catalog_revision:$catalog_revision,policy_revision:$policy_revision,usage_observed_at:$usage_observed_at,usage_uncertain:$usage_uncertain}}] | .updated_at=$now' "$ledger_path" >"$tmp"
  mv -f "$tmp" "$ledger_path"
  jq -c --arg id "$reservation_id" '.reservations[] | select(.reservation_id == $id)' "$ledger_path"
  exit 0
fi

[ -n "$reservation_id" ] || fail '--reservation-id is required'
jq -e --arg id "$reservation_id" 'any(.reservations[]?; .reservation_id == $id)' "$ledger_path" >/dev/null 2>&1 || fail "reservation not found: $reservation_id" 4
[ "$command_name" = release ] && state='released'
[ -n "$state" ] || state='recovered'
case "$state" in released|completed|cancelled|failed|recovered) ;; *) fail "invalid terminal state: $state" ;; esac
tmp="$ledger_path.tmp.$$"
jq --arg id "$reservation_id" --arg state "$state" --arg reason "${reason:-$state}" --arg now "$(now)" '(.reservations[] | select(.reservation_id == $id)) |= (.state=$state | .updated_at=$now | .released_at=$now | .release_reason=$reason) | .updated_at=$now' "$ledger_path" >"$tmp"
mv -f "$tmp" "$ledger_path"
jq -c --arg id "$reservation_id" '.reservations[] | select(.reservation_id == $id)' "$ledger_path"
