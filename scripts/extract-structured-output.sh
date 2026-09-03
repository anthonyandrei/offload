#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [--array] RESULT.json...\n' "$0" >&2
}

array_mode=false
if [ "${1:-}" = '--array' ]; then
  array_mode=true
  shift
fi

[ "$#" -gt 0 ] || { usage; exit 2; }

for result_path in "$@"; do
  [ -f "$result_path" ] || {
    printf 'ERROR: result file not found: %s\n' "$result_path" >&2
    exit 2
  }
done

if "$array_mode"; then
  jq -c -s '
    if any(.[]; (type != "object") or (has("structured_output") | not) or (.structured_output | type) != "object") then
      error("every result must contain a non-null structured_output object")
    else
      map(.structured_output)
    end
  ' "$@"
else
  jq -c '
    if (type != "object") or (has("structured_output") | not) or (.structured_output | type) != "object" then
      error("every result must contain a non-null structured_output object")
    else
      .structured_output
    end
  ' "$@"
fi
