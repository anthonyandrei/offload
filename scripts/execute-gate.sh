#!/usr/bin/env bash
# scripts/execute-gate.sh
# Public shared gate execution and exit normalization helper for Bash.

set -euo pipefail

show_usage() {
  cat >&2 <<'EOF'
Usage: execute-gate.sh --command <COMMAND> [--diagnostic-path <PATH>] [--workspace <DIR>]

Runs a machine gate command, preserves stdout/stderr diagnostics in an artifact file,
and normalizes gate exit codes to structured failure classes and verification statuses:
  Exit 0:         failure_class="none", verification_status="passed", allow_retry=false
  Exit 126, 127:  failure_class="unrunnable", verification_status="not_performed", allow_retry=false
  Other non-zero: failure_class="quality", verification_status="failed", allow_retry=true

Outputs JSON with command, exit_code, failure_class, verification_status, allow_retry,
and diagnostic_artifact_path.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

command=''
diagnostic_path=''
workspace=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -ge 2 ] || fail '--command requires a command string'
      command="$2"
      shift 2
      ;;
    --command=*)
      command="${1#--command=}"
      shift
      ;;
    -c)
      [ "$#" -ge 2 ] || fail '-c requires a command string'
      command="$2"
      shift 2
      ;;
    --diagnostic-path)
      [ "$#" -ge 2 ] || fail '--diagnostic-path requires a path'
      diagnostic_path="$2"
      shift 2
      ;;
    --diagnostic-path=*)
      diagnostic_path="${1#--diagnostic-path=}"
      shift
      ;;
    --diagnostic-file)
      [ "$#" -ge 2 ] || fail '--diagnostic-file requires a path'
      diagnostic_path="$2"
      shift 2
      ;;
    --diagnostic-file=*)
      diagnostic_path="${1#--diagnostic-file=}"
      shift
      ;;
    --output)
      [ "$#" -ge 2 ] || fail '--output requires a path'
      diagnostic_path="$2"
      shift 2
      ;;
    --output=*)
      diagnostic_path="${1#--output=}"
      shift
      ;;
    --workspace)
      [ "$#" -ge 2 ] || fail '--workspace requires a path'
      workspace="$2"
      shift 2
      ;;
    --workspace=*)
      workspace="${1#--workspace=}"
      shift
      ;;
    --cwd)
      [ "$#" -ge 2 ] || fail '--cwd requires a path'
      workspace="$2"
      shift 2
      ;;
    --cwd=*)
      workspace="${1#--cwd=}"
      shift
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      show_usage
      fail "unrecognized option: $1"
      ;;
  esac
done

if [ -z "$command" ]; then
  show_usage
  fail 'missing required option --command'
fi

if [ -z "$diagnostic_path" ]; then
  diag_dir="${TMPDIR:-/tmp}/offload-gate-diagnostics"
  mkdir -p "$diag_dir"
  diagnostic_path="$(mktemp "$diag_dir/gate-XXXXXX.log" 2>/dev/null || printf '%s/gate-%s-%s.log' "$diag_dir" "$$" "$(date +%s)")"
  touch "$diagnostic_path"
else
  mkdir -p "$(dirname "$diagnostic_path")"
  touch "$diagnostic_path"
fi

set +e
if [ -n "$workspace" ]; then
  ( cd "$workspace" && "${BASH:-bash}" -c "$command" ) >"$diagnostic_path" 2>&1
  raw_exit=$?
else
  "${BASH:-bash}" -c "$command" >"$diagnostic_path" 2>&1
  raw_exit=$?
fi
set -e

if [ "$raw_exit" -eq 0 ]; then
  failure_class="none"
  verification_status="passed"
  allow_retry=false
elif [ "$raw_exit" -eq 126 ] || [ "$raw_exit" -eq 127 ]; then
  failure_class="unrunnable"
  verification_status="not_performed"
  allow_retry=false
else
  failure_class="quality"
  verification_status="failed"
  allow_retry=true
fi

if command -v jq >/dev/null 2>&1; then
  jq -n -c \
    --arg cmd "$command" \
    --argjson ec "$raw_exit" \
    --arg fc "$failure_class" \
    --arg vs "$verification_status" \
    --argjson ar "$allow_retry" \
    --arg dp "$diagnostic_path" \
    '{
      command: $cmd,
      exit_code: $ec,
      failure_class: $fc,
      verification_status: $vs,
      allow_retry: $ar,
      diagnostic_artifact_path: $dp
    }'
elif command -v python3 >/dev/null 2>&1; then
  python3 -c '
import json, sys
data = {
    "command": sys.argv[1],
    "exit_code": int(sys.argv[2]),
    "failure_class": sys.argv[3],
    "verification_status": sys.argv[4],
    "allow_retry": sys.argv[5].lower() == "true",
    "diagnostic_artifact_path": sys.argv[6]
}
print(json.dumps(data))
' "$command" "$raw_exit" "$failure_class" "$verification_status" "$allow_retry" "$diagnostic_path"
else
  esc_cmd=$(printf '%s' "$command" | sed 's/\\/\\\\/g; s/"/\\"/g')
  esc_dp=$(printf '%s' "$diagnostic_path" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"command":"%s","exit_code":%d,"failure_class":"%s","verification_status":"%s","allow_retry":%s,"diagnostic_artifact_path":"%s"}\n' \
    "$esc_cmd" "$raw_exit" "$failure_class" "$verification_status" "$allow_retry" "$esc_dp"
fi

exit 0
