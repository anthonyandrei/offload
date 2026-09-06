#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-2}"; }

operation=''
request_path=''
output_path=''
error_path=''
worker_args=()
after_delimiter=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --operation|--request|--output|--error)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in
        --operation) operation="$2" ;;
        --request) request_path="$2" ;;
        --output) output_path="$2" ;;
        --error) error_path="$2" ;;
      esac
      shift 2
      ;;
    --)
      after_delimiter=true
      shift
      worker_args=("$@")
      break
      ;;
    *) fail "unknown adapter option: $1" ;;
  esac
done

[ "$operation" = catalog ] || [ "$operation" = launch ] || fail 'operation must be catalog or launch'
[ -n "$request_path" ] && [ -f "$request_path" ] || fail 'request file is required'

agy_bin="${AGY_BIN:-agy}"
if [ "$operation" = catalog ]; then
  if [ -n "${OFFLOAD_ADAPTER_CATALOG:-}" ]; then
    [ -f "$OFFLOAD_ADAPTER_CATALOG" ] || fail "catalog file not found: $OFFLOAD_ADAPTER_CATALOG" 127
    jq empty "$OFFLOAD_ADAPTER_CATALOG" >/dev/null 2>&1 || fail 'catalog file is not valid JSON' 127
    cat "$OFFLOAD_ADAPTER_CATALOG"
    exit 0
  fi
  models_tmp=$(mktemp)
  models_err=$(mktemp)
  usage_tmp=''
  usage_err=''
  usage_snapshot=''
  bounded_marker=''
  trap 'rm -f "$models_tmp" "$models_err" "$usage_tmp" "$usage_err" "$usage_snapshot" "$usage_snapshot.tmp" "$bounded_marker"' EXIT
  terminate_descendants() {
    local parent="$1"
    local child
    if command -v pgrep >/dev/null 2>&1; then
      for child in $(pgrep -P "$parent" 2>/dev/null || true); do
        terminate_descendants "$child"
        kill -TERM "$child" 2>/dev/null || true
      done
    fi
  }
  terminate_bounded() {
    local pid="$1"
    local process_group="$2"
    if [ "$process_group" = true ]; then
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    else
      terminate_descendants "$pid"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      terminate_descendants "$pid"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  }
  run_bounded() {
    local stdout_path="$1"
    local stderr_path="$2"
    local pid
    local process_group=false
    local ticks=0
    shift 2
    if command -v setsid >/dev/null 2>&1; then
      setsid "$@" >"$stdout_path" 2>"$stderr_path" &
      pid=$!
      process_group=true
    else
      "$@" >"$stdout_path" 2>"$stderr_path" &
      pid=$!
    fi
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$ticks" -ge 15 ]; then
        terminate_bounded "$pid" "$process_group"
        wait "$pid" 2>/dev/null || true
        bounded_timed_out=true
        bounded_code=124
        return 0
      fi
      sleep 1
      ticks=$((ticks + 1))
    done
    if wait "$pid"; then bounded_code=0; else bounded_code=$?; fi
    bounded_timed_out=false
  }
  run_with_timeout() {
    local stdout_path="$1"
    local stderr_path="$2"
    local timeout_code
    shift 2
    bounded_marker=$(mktemp)
    AGY_TIMEOUT_MARKER="$bounded_marker" timeout --signal=TERM --kill-after=2s 15s sh -c '
      "$@"
      command_code=$?
      printf "%s\n" "$command_code" >"$AGY_TIMEOUT_MARKER"
      exit "$command_code"
    ' offload-agy-discovery "$@" >"$stdout_path" 2>"$stderr_path"
    timeout_code=$?
    if [ -s "$bounded_marker" ] && grep -Eq '^[0-9]+$' "$bounded_marker"; then
      bounded_timed_out=false
      bounded_code=$(cat "$bounded_marker")
    else
      bounded_timed_out=true
      bounded_code=$timeout_code
    fi
    rm -f "$bounded_marker"
    bounded_marker=''
  }
  if ! command -v timeout >/dev/null 2>&1 && ! command -v setsid >/dev/null 2>&1 && ! command -v pgrep >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: bounded AGY discovery requires timeout, setsid, or pgrep for process cleanup' >&2
    exit 127
  fi
  set +e
  models_timed_out=false
  models_code=0
  if command -v timeout >/dev/null 2>&1; then
    run_with_timeout "$models_tmp" "$models_err" "$agy_bin" models
    models_timed_out=$bounded_timed_out
    models_code=$bounded_code
  else
    run_bounded "$models_tmp" "$models_err" "$agy_bin" models
    models_timed_out=$bounded_timed_out
    models_code=$bounded_code
  fi
  if [ "$models_timed_out" = true ]; then
    printf 'ERROR: AGY catalog discovery timed out\n' >&2
    exit 127
  fi
  set -e
  if [ "$models_code" -ne 0 ]; then
    printf 'ERROR: AGY catalog discovery failed with exit code %s\n' "$models_code" >&2
    exit 127
  fi
  usage_tmp=$(mktemp)
  usage_err=$(mktemp)
  usage_snapshot=$(mktemp)
  set +e
  usage_timed_out=false
  usage_code=0
  if command -v timeout >/dev/null 2>&1; then
    run_with_timeout "$usage_tmp" "$usage_err" "$agy_bin" -p /usage --output-format json --print-timeout 15s
    usage_timed_out=$bounded_timed_out
    usage_code=$bounded_code
  else
    run_bounded "$usage_tmp" "$usage_err" "$agy_bin" -p /usage --output-format json --print-timeout 15s
    usage_timed_out=$bounded_timed_out
    usage_code=$bounded_code
  fi
  if [ "$usage_timed_out" = true ]; then
    printf '%s\n' '{"ok":false,"reason":"AGY usage probe timed out","groups":{}}' >"$usage_snapshot"
  else
    if [ "$usage_code" -ne 0 ]; then
      printf '%s\n' "{\"ok\":false,\"reason\":\"AGY usage probe failed with exit code $usage_code\",\"groups\":{}}" >"$usage_snapshot"
    elif ! jq -c '
      def source_groups:
        if ((.command.data.groups? // null) | type) == "array" then .command.data.groups
        elif ((.command.groups? // null) | type) == "array" then .command.groups
        elif ((.groups? // null) | type) == "array" then .groups
        else [] end;
      def group_key:
        ((.id // .name // "") | strings | ascii_downcase) as $name
        | if ($name | contains("gemini")) then "gemini"
          elif (($name | contains("claude")) and ($name | contains("gpt"))) then "claude-and-gpt"
          else "" end;
      def valid_scopes:
        (.buckets? // []) as $buckets
        | if ($buckets | type) == "array" then $buckets else [] end
        | map(select(
            (type == "object") and
            ((.id? | type) == "string") and (.id | length > 0) and
            ((.window? | type) == "string") and (.window | length > 0) and
            ((.remaining_fraction? | type) == "number") and
            (.remaining_fraction >= 0 and .remaining_fraction <= 1) and
            ((.reset_time? | type) == "string") and
            ((try (.reset_time | fromdateiso8601) catch null) != null)
          ))
        | map({scope_id:.id,window:.window,remaining_units:.remaining_fraction,reserved_units:0,reset_at:(.reset_time | fromdateiso8601 | todateiso8601)});
      if (((.status // "") | tostring | ascii_upcase) != "SUCCESS") then
        {ok:false,reason:"AGY usage probe returned a non-success status",groups:{}}
      else
        ([source_groups[]? | . as $group | ($group | group_key) as $key | select($key != "") | {key:$key,scopes:($group | valid_scopes)}]) as $recognized
        | ([ $recognized[] | select((.scopes | length) > 0) ]) as $valid
        | if ($valid | length) == 0 then
            {ok:false,reason:(if ($recognized | length) > 0 then "AGY usage probe returned no valid group-level usage bucket" else "AGY usage probe did not expose supported group-level usage" end),groups:{}}
          else
            {ok:true,reason:"",observed_at:(now | todateiso8601),groups:(reduce $valid[] as $item ({}; .[$item.key] = $item.scopes))}
          end
      end
    ' "$usage_tmp" >"$usage_snapshot" 2>/dev/null; then
      printf '%s\n' '{"ok":false,"reason":"AGY usage probe returned malformed JSON","groups":{}}' >"$usage_snapshot"
    fi
  fi
  set -e
  catalog_revision=''
  if command -v sha256sum >/dev/null 2>&1; then
    catalog_revision=$(sha256sum "$models_tmp" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    catalog_revision=$(shasum -a 256 "$models_tmp" | awk '{print $1}')
  else
    printf 'ERROR: no SHA-256 implementation is available for catalog revision\n' >&2
    exit 127
  fi
  jq -Rn --arg revision "$catalog_revision" --slurpfile usage "$usage_snapshot" '
    def family:
      if test("^gemini-[^-]+-flash-") then "flash"
      elif test("^gemini-[^-]+-pro-") then "pro"
      elif test("^claude-[^-]+-opus") then "opus"
      elif test("^claude-[^-]+-sonnet") then "sonnet"
      elif test("^claude-[^-]+-haiku") then "haiku"
      elif test("^gpt-oss-") then "oss"
      else "unknown" end;
    def score($family; $preference):
      if $preference == "fast" then ({flash:1,haiku:2,oss:2,sonnet:3,pro:4,opus:5,unknown:100}[$family] // 100)
      elif $preference == "balanced" then ({sonnet:1,flash:2,oss:3,pro:3,haiku:4,opus:5,unknown:100}[$family] // 100)
      else ({opus:1,pro:2,sonnet:3,oss:4,flash:5,haiku:6,unknown:100}[$family] // 100) end;
    def usage_group:
      if startswith("gemini-") then "gemini"
      elif (startswith("claude-") or startswith("gpt-")) then "claude-and-gpt"
      else null end;
    ($usage[0] // {ok:false,reason:"AGY usage probe did not expose supported group-level usage",groups:{}}) as $usage_result |
    {
      protocol_version: 2,
      adapter: "agy",
      adapter_revision: "agy-3",
      vendor: "agy",
      catalog_revision: $revision,
      models: [
        inputs
        | capture("^\\s*(?<id>\\S+)\\s+(?<label>.+?)\\s*$")
        | select(.id | test("-(low|medium|high)$"))
        | (.id | capture("-(?<effort>low|medium|high)$")) as $effort
        | (.id | family) as $family
        | (.id | usage_group) as $usage_group
        | (if $usage_group != null and (($usage_result.groups[$usage_group] // []) | length) > 0 then
             {state:"unknown",reason:"AGY usage exposes group-level fractions without protocol capacity units or reservation data",source:"agy-usage",observed_at:($usage_result.observed_at // ""),scopes:[]}
           else
             {state:"unknown",reason:(if $usage_group == null then "AGY model ID is not mapped to a supported usage group" elif ($usage_result.reason // "") != "" then $usage_result.reason else ("AGY usage probe returned no valid usage bucket for model group " + $usage_group) end),source:"agy-usage",observed_at:"",scopes:[]}
           end) as $usage_record
        | {
            id: .id,
            family_hint: $family,
            supported_efforts: [$effort.effort],
            capabilities: [],
            scores: {
              fast: score($family; "fast"),
              balanced: score($family; "balanced"),
              deep: score($family; "deep")
            },
            preflight: {access:{state:"unknown",reason:"AGY headless discovery does not expose a non-secret account identifier",account_ref:""},entitlement:{state:"unknown",reason:"AGY headless discovery does not expose model entitlement",billing_route:"unknown"},usage:$usage_record}
          }
      ]
    }
  ' "$models_tmp"
  exit 0
fi

$after_delimiter && [ "${#worker_args[@]}" -gt 0 ] || fail 'worker arguments are required after --'
[ -n "$output_path" ] && [ -n "$error_path" ] || fail 'launch requires output and error paths'
model_id=$(jq -er '.model_id // .model // empty' "$request_path") || fail 'selection is missing model_id'

# AGY accepts the exact model ID here. The launcher never needs to know this syntax.
set +e
"$agy_bin" --model "$model_id" "${worker_args[@]}" >"$output_path" 2>"$error_path"
code=$?
set -e
exit "$code"
