#!/usr/bin/env bash
# scripts/run-claude-json.sh
# Claude worker adapter. Conforms to the adapter contract (--operation catalog | launch).
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() {
  printf 'Usage: %s --operation catalog --request REQUEST.json [--claude PATH]\n' "$0" >&2
  printf '       %s --operation launch --request SELECTION.json --output OUTPUT --error ERROR [--claude PATH] [--cancel-file FILE] [--timeout-seconds N] -- WORKER_ARGS...\n' "$0" >&2
}

operation=''
request_path=''
output_path=''
error_path=''
claude_path=''
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
    --operation|--request|--output|--error|--claude|--cancel-file|--timeout-seconds)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in
        --operation) operation="$2" ;;
        --request) request_path="$2" ;;
        --output) output_path="$2" ;;
        --error) error_path="$2" ;;
        --claude) claude_path="$2" ;;
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

resolve_claude() {
  if [ -n "$1" ] && [ -x "$1" ]; then printf '%s\n' "$1"
  elif [ -n "$1" ] && command -v "$1" >/dev/null 2>&1; then command -v "$1"
  elif [ -n "${CLAUDE_BIN:-}" ] && command -v "$CLAUDE_BIN" >/dev/null 2>&1; then command -v "$CLAUDE_BIN"
  elif command -v claude >/dev/null 2>&1; then command -v claude
  else fail 'claude was not found; set CLAUDE_BIN or add claude to PATH' 127
  fi
}

claude_bin=$(resolve_claude "$claude_path")

if [ "$operation" = catalog ]; then
  probe_err=$(mktemp)
  probe_out=$(mktemp)
  trap 'rm -f "$probe_err" "$probe_out"' EXIT
  set +e
  "$claude_bin" --help >"$probe_out" 2>"$probe_err"
  probe_code=$?
  set -e
  probe_text=$(cat "$probe_out")
  if [ "$probe_code" -ne 0 ] || [[ "$probe_text" != *--output-format* ]]; then
    fail 'Claude CLI does not advertise structured JSON output' 127
  fi

  catalog_source="${OFFLOAD_ADAPTER_CATALOG:-${CLAUDE_MODEL_CATALOG:-}}"
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
    def family_for($id):
      if ($id | test("opus")) then "opus"
      elif ($id | test("sonnet")) then "sonnet"
      elif ($id | test("haiku")) then "haiku"
      else "unknown" end;
    def score_map($fam):
      if $fam == "haiku" then {fast: 1, balanced: 2, deep: 3}
      elif $fam == "sonnet" then {fast: 2, balanced: 1, deep: 2}
      elif $fam == "opus" then {fast: 3, balanced: 2, deep: 1}
      else {fast: 100, balanced: 100, deep: 100} end;
    {
      protocol_version: 1,
      adapter: "claude",
      adapter_revision: "claude-1",
      vendor: "anthropic",
      catalog_revision: (.revision // "claude-current"),
      models: [
        .models[] |
        (if type == "string" then {id: .} else . end) |
        ((.family_hint // family_for(.id)) as $fam |
        {
          id: .id,
          family_hint: $fam,
          available: (if has("available") then .available else true end),
          quota_available: (if has("quota_available") then .quota_available else true end),
          supported_efforts: (.supported_efforts // .efforts // ["low", "medium", "high"]),
          capabilities: (.capabilities // ["structured-output"]),
          scores: (.scores // score_map($fam))
        })
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
permission_mode='acceptEdits'
resume_session=''
allowed_tools=()
disallowed_tools=(Task Agent)

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
    --permission-mode)
      idx=$((idx + 1))
      [ "$idx" -lt "${#worker_args[@]}" ] && permission_mode="${worker_args[$idx]}"
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
    --allowedTools|--allowed-tools)
      idx=$((idx + 1))
      [ "$idx" -lt "${#worker_args[@]}" ] && allowed_tools+=("${worker_args[$idx]}")
      idx=$((idx + 1))
      ;;
    --disallowedTools|--disallowed-tools)
      idx=$((idx + 1))
      [ "$idx" -lt "${#worker_args[@]}" ] && disallowed_tools+=("${worker_args[$idx]}")
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

[ "$permission_mode" != bypassPermissions ] || fail 'bypassPermissions is not allowed'

[ -n "$worktree" ] || worktree="$(pwd -P)"
[ -d "$worktree" ] || fail "working directory does not exist: $worktree"

marker_file="$worktree/.offload-execution-workspace"
marker_value='offload-execution-workspace-v1'
if [ ! -f "$marker_file" ]; then
  marker_file="$worktree/.offload-research-workspace"
  marker_value='offload-research-workspace-v1'
fi
[ -f "$marker_file" ] || fail 'unsupported or unmarked sandbox; use an isolated offload workspace'
[ "$(tr -d '\r\n' <"$marker_file")" = "$marker_value" ] || fail 'invalid isolated workspace marker'

raw_out=$(mktemp)
raw_err=$(mktemp)
cleanup_launch() {
  rm -f "$raw_out" "$raw_err"
}
trap cleanup_launch EXIT

claude_cmd=(
  "$claude_bin"
  -p "$prompt"
  --output-format json
  --permission-mode "$permission_mode"
)
for t in "${disallowed_tools[@]}"; do
  claude_cmd+=(--disallowedTools "$t")
done
for t in "${allowed_tools[@]}"; do
  claude_cmd+=(--allowedTools "$t")
done
if [ -n "$model_id" ]; then
  claude_cmd+=(--model "$model_id")
fi
if [ -n "$resume_session" ]; then
  claude_cmd+=(--resume "$resume_session")
fi

start_time=$(date +%s)
set +e
(cd "$worktree" && exec "${claude_cmd[@]}") >"$raw_out" 2>"$raw_err" &
claude_pid=$!
set -e

termination=natural
while kill -0 "$claude_pid" 2>/dev/null; do
  if [ -n "$cancel_file" ] && [ -f "$cancel_file" ]; then
    termination=canceled
    kill -9 "$claude_pid" 2>/dev/null || true
    break
  fi
  now=$(date +%s)
  if [ "$timeout_seconds" -gt 0 ] && [ $((now - start_time)) -ge "$timeout_seconds" ]; then
    termination=timeout
    kill -9 "$claude_pid" 2>/dev/null || true
    break
  fi
  sleep 0.05
done

set +e
wait "$claude_pid" 2>/dev/null
proc_exit=$?
set -e

cat "$raw_err" >"$error_path"

if [ "$termination" = canceled ]; then exit 130; fi
if [ "$termination" = timeout ]; then exit 124; fi

if [ "$proc_exit" -eq 75 ] || grep -Eiq 'quota|rate limit|too many requests|429' "$raw_out" "$raw_err" 2>/dev/null; then
  exit 75
fi

if [ "$proc_exit" -eq 0 ]; then
  if jq empty "$raw_out" >/dev/null 2>&1 && jq -e '(.subtype == "success") or (.status == "success")' "$raw_out" >/dev/null 2>&1; then
    jq -c --arg model "$model_id" '
      {
        status: "success",
        response: (.result // .response // null),
        session_id: (.session_id // null),
        structured_output: .,
        model_id: $model
      }
    ' "$raw_out" >"$output_path"
    exit 0
  else
    cat "$raw_out" >"$output_path"
    fail 'malformed Claude JSON output' 1
  fi
fi

cat "$raw_out" >"$output_path"
exit "$proc_exit"
