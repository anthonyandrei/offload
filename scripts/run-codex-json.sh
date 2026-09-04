#!/usr/bin/env bash
# scripts/run-codex-json.sh
# Codex worker adapter. Conforms to the adapter contract (--operation catalog | launch).
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() {
  printf 'Usage: %s --operation catalog --request REQUEST.json [--codex PATH]\n' "$0" >&2
  printf '       %s --operation launch --request SELECTION.json --output OUTPUT --error ERROR [--codex PATH] [--cancel-file FILE] [--timeout-seconds N] -- WORKER_ARGS...\n' "$0" >&2
}

operation=''
request_path=''
output_path=''
error_path=''
codex_path=''
cancel_file=''
timeout_seconds=0
worker_args=()
after_delimiter=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --)
      after_delimiter=true
      shift
      worker_args=("$@")
      break
      ;;
    --operation|--request|--output|--error|--codex|--cancel-file|--timeout-seconds)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in
        --operation) operation="$2" ;;
        --request) request_path="$2" ;;
        --output) output_path="$2" ;;
        --error) error_path="$2" ;;
        --codex) codex_path="$2" ;;
        --cancel-file) cancel_file="$2" ;;
        --timeout-seconds) timeout_seconds="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown adapter option: $1" ;;
  esac
done

[ "$operation" = catalog ] || [ "$operation" = launch ] || fail 'operation must be catalog or launch'
[ -n "$request_path" ] && [ -f "$request_path" ] || fail 'request file is required and must exist'

resolve_codex() {
  if [ -n "$1" ] && [ -x "$1" ]; then printf '%s\n' "$1"
  elif [ -n "$1" ] && command -v "$1" >/dev/null 2>&1; then command -v "$1"
  elif [ -n "${CODEX_BIN:-}" ] && command -v "$CODEX_BIN" >/dev/null 2>&1; then command -v "$CODEX_BIN"
  elif command -v codex >/dev/null 2>&1; then command -v codex
  else fail 'Codex executable was not found on PATH or via CODEX_BIN' 127
  fi
}

codex_bin=$(resolve_codex "$codex_path")

if [ "$operation" = catalog ]; then
  probe_err=$(mktemp)
  probe_out=$(mktemp)
  trap 'rm -f "$probe_err" "$probe_out"' EXIT
  set +e
  "$codex_bin" --help >"$probe_out" 2>"$probe_err"
  probe_code=$?
  set -e
  probe_text=$(cat "$probe_out")
  if [ "$probe_code" -ne 0 ] || [[ "$probe_text" != *--json* ]] || [[ "$probe_text" != *--output-schema* ]] || [[ "$probe_text" != *--output-last-message* ]]; then
    fail 'host lacks required structured-output flags' 127
  fi

  catalog_source="${OFFLOAD_ADAPTER_CATALOG:-${CODEX_MODEL_CATALOG:-}}"
  [ -n "$catalog_source" ] || fail 'host does not expose a model catalog' 127

  catalog_raw=''
  if [ -f "$catalog_source" ]; then
    catalog_raw=$(cat "$catalog_source")
  else
    catalog_raw="$catalog_source"
  fi
  jq empty <<<"$catalog_raw" >/dev/null 2>&1 || fail 'host does not expose a valid model catalog' 127
  model_count=$(jq -r '(.models // []) | length' <<<"$catalog_raw")
  [ "$model_count" -gt 0 ] || fail 'host does not expose a model catalog' 127

  jq -c '
    def score_map($pref):
      if $pref == "fast" then {fast: 1, balanced: 2, deep: 3}
      elif $pref == "balanced" then {fast: 2, balanced: 1, deep: 2}
      elif $pref == "deep" then {fast: 3, balanced: 2, deep: 1}
      else {fast: 100, balanced: 100, deep: 100} end;
    {
      protocol_version: 1,
      adapter: "codex",
      adapter_revision: "codex-1",
      vendor: "codex",
      catalog_revision: (.revision // "codex-current"),
      models: [
        .models[] | {
          id: .id,
          family_hint: (.family_hint // "unknown"),
          available: (if has("available") then .available else true end),
          quota_available: (if has("quota_available") then .quota_available else true end),
          supported_efforts: (.supported_efforts // .efforts // ["low", "medium", "high"]),
          capabilities: (.capabilities // ["structured-output"]),
          scores: (.scores // score_map(.preference // "balanced"))
        }
      ]
    }
  ' <<<"$catalog_raw"
  exit 0
fi

# Launch operation
$after_delimiter && [ "${#worker_args[@]}" -gt 0 ] || fail 'worker arguments are required after --'
[ -n "$output_path" ] && [ -n "$error_path" ] || fail 'launch requires output and error paths'

mkdir -p "$(dirname "$output_path")" "$(dirname "$error_path")"
model_id=$(jq -er '.model_id // .model // empty' "$request_path") || fail 'selection is missing model_id'

prompt=''
worktree=''
schema_path=''
resume_session=''

idx=0
while [ "$idx" -lt "${#worker_args[@]}" ]; do
  arg="${worker_args[$idx]}"
  case "$arg" in
    --)
      idx=$((idx + 1))
      if [ "$idx" -lt "${#worker_args[@]}" ]; then
        prompt="${worker_args[$idx]}"
        idx=$((idx + 1))
      fi
      break
      ;;
    -p|--prompt)
      idx=$((idx + 1))
      [ "$idx" -lt "${#worker_args[@]}" ] && prompt="${worker_args[$idx]}"
      idx=$((idx + 1))
      ;;
    --prompt=*)
      prompt="${arg#*=}"
      idx=$((idx + 1))
      ;;
    --cd|-C|--working-directory)
      idx=$((idx + 1))
      [ "$idx" -lt "${#worker_args[@]}" ] && worktree="${worker_args[$idx]}"
      idx=$((idx + 1))
      ;;
    --cd=*)
      worktree="${arg#*=}"
      idx=$((idx + 1))
      ;;
    --output-schema|--json-schema)
      idx=$((idx + 1))
      [ "$idx" -lt "${#worker_args[@]}" ] && schema_path="${worker_args[$idx]}"
      idx=$((idx + 1))
      ;;
    --resume|--resume-session)
      idx=$((idx + 1))
      [ "$idx" -lt "${#worker_args[@]}" ] && resume_session="${worker_args[$idx]}"
      idx=$((idx + 1))
      ;;
    --cancel-file)
      idx=$((idx + 1))
      [ "$idx" -lt "${#worker_args[@]}" ] && cancel_file="${worker_args[$idx]}"
      idx=$((idx + 1))
      ;;
    --timeout-seconds)
      idx=$((idx + 1))
      [ "$idx" -lt "${#worker_args[@]}" ] && timeout_seconds="${worker_args[$idx]}"
      idx=$((idx + 1))
      ;;
    *)
      if [ -z "$prompt" ] && [[ "$arg" != -* ]]; then
        prompt="$arg"
      fi
      idx=$((idx + 1))
      ;;
  esac
done

[ -n "$worktree" ] || worktree="$(pwd -P)"
[ -d "$worktree" ] || fail "worktree does not exist: $worktree"

temp_schema=''
if [ -z "$schema_path" ] || [ ! -f "$schema_path" ]; then
  temp_schema=$(mktemp)
  printf '%s\n' '{"type":"object","additionalProperties":true}' > "$temp_schema"
  schema_path="$temp_schema"
fi

last_message=$(mktemp)
raw_out=$(mktemp)
cleanup_launch() {
  rm -f "$last_message" "$raw_out"
  [ -z "$temp_schema" ] || rm -f "$temp_schema"
}
trap cleanup_launch EXIT

codex_cmd=("$codex_bin" exec)
if [ -n "$resume_session" ]; then
  codex_cmd=("$codex_bin" exec resume "$resume_session")
fi
codex_cmd+=(
  --json --ephemeral --cd "$worktree"
  --sandbox workspace-write --ask-for-approval never
  --output-schema "$schema_path"
  --output-last-message "$last_message"
  --model "$model_id"
  -- "$prompt"
)

start_time=$(date +%s)
set +e
"${codex_cmd[@]}" >"$raw_out" 2>"$error_path" &
codex_pid=$!
set -e

termination=natural
while kill -0 "$codex_pid" 2>/dev/null; do
  if [ -n "$cancel_file" ] && [ -f "$cancel_file" ]; then
    termination=canceled
    kill -9 "$codex_pid" 2>/dev/null || true
    break
  fi
  now=$(date +%s)
  if [ "$timeout_seconds" -gt 0 ] && [ $((now - start_time)) -ge "$timeout_seconds" ]; then
    termination=timeout
    kill -9 "$codex_pid" 2>/dev/null || true
    break
  fi
  sleep 0.05
done

set +e
wait "$codex_pid" 2>/dev/null
proc_exit=$?
set -e

if [ "$termination" = canceled ]; then exit 130; fi
if [ "$termination" = timeout ]; then exit 124; fi

if [ "$proc_exit" -eq 75 ] || grep -Eiq 'quota|rate.?limit' "$raw_out" "$error_path" 2>/dev/null; then
  exit 75
fi

if [ -f "$last_message" ]; then
  if grep -Eiq 'quota|rate.?limit' "$last_message" 2>/dev/null; then
    cat "$last_message" >"$error_path"
    exit 75
  fi
  if ! jq empty "$last_message" >/dev/null 2>&1; then
    cat "$last_message" >"$output_path"
    fail 'malformed worker JSON output' 1
  fi
  if ! jq -e 'has("structured_output") and (.structured_output | type == "object")' "$last_message" >/dev/null 2>&1; then
    cat "$last_message" >"$output_path"
    fail 'last-message artifact lacks structured_output' 1
  fi
  if jq -e '.status? and (.status | test("(?i)quota|rate.?limit"))' "$last_message" >/dev/null 2>&1; then
    exit 75
  fi
  jq -c --arg model "$model_id" '
    {
      status: "success",
      structured_output: .structured_output,
      model_id: $model
    } + (if has("child_assignment_request") then {child_assignment_request: .child_assignment_request} else {} end)
  ' "$last_message" >"$output_path"

  if [ "$proc_exit" -ne 0 ]; then exit "$proc_exit"; fi
  exit 0
fi

fail 'Codex did not produce the required last-message artifact' 1
