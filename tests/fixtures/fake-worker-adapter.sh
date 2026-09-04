#!/usr/bin/env bash
set -euo pipefail

operation=''
request=''
output=''
error=''
worker_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --operation) operation="$2"; shift 2 ;;
    --request) request="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --error) error="$2"; shift 2 ;;
    --) shift; worker_args=("$@"); break ;;
    *) echo "unknown fake adapter option: $1" >&2; exit 2 ;;
  esac
done

if [ "$operation" = catalog ]; then
  cat "${FAKE_ADAPTER_CATALOG:?FAKE_ADAPTER_CATALOG is required}"
  exit 0
fi
[ "$operation" = launch ] || { echo 'fake adapter operation must be catalog or launch' >&2; exit 2; }

selection_json=$(cat "$request")
if [ -n "${FAKE_ADAPTER_CAPTURE:-}" ]; then
  jq -n --slurpfile selection "$request" --args \
    '{selection:$selection[0],worker_args:$ARGS.positional}' -- "${worker_args[@]}" > "$FAKE_ADAPTER_CAPTURE"
fi
if [ -n "${AGY_BIN:-}" ]; then
  if [[ "$AGY_BIN" == */* ]]; then
    [ -x "$AGY_BIN" ] || { echo "fake worker executable not found: $AGY_BIN" >&2; exit 127; }
  else
    command -v "$AGY_BIN" >/dev/null 2>&1 || { echo "fake worker executable not found: $AGY_BIN" >&2; exit 127; }
  fi
  set +e
  "$AGY_BIN" --model "$(jq -r '.model_id' <<<"$selection_json")" --effort "$(jq -r '.effort' <<<"$selection_json")" "${worker_args[@]}" > "$output" 2> "$error"
  exit_code=$?
  set -e
  exit "$exit_code"
fi
jq -n --slurpfile selection "$request" --args \
  '{status:"SUCCESS",model_id:$selection[0].model_id,effort:$selection[0].effort,worker_args:$ARGS.positional}' -- "${worker_args[@]}" > "$output"
: > "$error"
exit "${FAKE_ADAPTER_LAUNCH_EXIT_CODE:-0}"
