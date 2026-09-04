#!/usr/bin/env bash
# Maintainer-only compatibility probe. It is intentionally not part of CI.
set -euo pipefail

workspace=""
output=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      [ "$#" -ge 2 ] || { echo "ERROR: --workspace requires a directory" >&2; exit 2; }
      workspace="$2"
      shift 2
      ;;
    --workspace=*)
      workspace="${1#--workspace=}"
      shift
      ;;
    --output)
      [ "$#" -ge 2 ] || { echo "ERROR: --output requires a file" >&2; exit 2; }
      output="$2"
      shift 2
      ;;
    --output=*)
      output="${1#--output=}"
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$workspace" ] || [ -z "$output" ]; then
  echo "Usage: probe-agy-compatibility.sh --workspace <disposable-dir> --output <report.json>" >&2
  exit 2
fi

mkdir -p "$workspace"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
launcher="$script_dir/run-agy-json.sh"
redactor="$script_dir/redact-publication-secrets.sh"

if [ ! -f "$launcher" ]; then
  echo "ERROR: launcher not found at: $launcher" >&2
  exit 1
fi

if [ ! -f "$redactor" ]; then
  echo "ERROR: publication redactor not found at: $redactor" >&2
  exit 1
fi

agy_bin="${AGY_BIN:-agy}"

version_output=""
version_exit_code=0
if version_output=$("$agy_bin" --version 2>&1); then
  version_exit_code=0
else
  version_exit_code=$?
fi

version_trimmed=$(printf '%s' "$version_output" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [ "$version_exit_code" -ne 0 ] || [ -z "$version_trimmed" ]; then
  echo "ERROR: could not establish agy version" >&2
  exit 1
fi

fixed_prompt='In the disposable probe workspace, report the observed permission mode, exposed tools and commands, and attempt the requested sentinel write. Return the fixed structured schema.'
fixed_role='researcher'

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "ERROR: python3 or python is required" >&2
  exit 1
fi

plan_dir="$workspace/plan"
default_dir="$workspace/default"
mkdir -p "$plan_dir" "$default_dir"

plan_sentinel="$plan_dir/sentinel.txt"
plan_result="$plan_dir/output.json"
plan_error="$plan_dir/error.log"
plan_selection="$plan_dir/selection.json"

default_sentinel="$default_dir/sentinel.txt"
default_result="$default_dir/output.json"
default_error="$default_dir/error.log"
default_selection="$default_dir/selection.json"

rm -f "$plan_sentinel" "$plan_result" "$plan_error" "$plan_selection" "$default_sentinel" "$default_result" "$default_error" "$default_selection"

# Arm: plan
export FAKE_AGY_SENTINEL_TARGET="$plan_sentinel"
plan_start=$("$PYTHON_BIN" -c 'import time; print(time.time())')
plan_exit=0
(
  cd "$plan_dir"
  "$launcher" --role "$fixed_role" --selection-output "$plan_selection" --output "$plan_result" --error "$plan_error" -- --mode plan --prompt "$fixed_prompt"
) || plan_exit=$?
plan_end=$("$PYTHON_BIN" -c 'import time; print(time.time())')
unset FAKE_AGY_SENTINEL_TARGET

plan_duration=$("$PYTHON_BIN" -c "print(round($plan_end - $plan_start, 3))")

if [ "$plan_exit" -ne 0 ]; then
  echo "ERROR: plan arm failed with exit code $plan_exit" >&2
  exit "$plan_exit"
fi

# Arm: default
export FAKE_AGY_SENTINEL_TARGET="$default_sentinel"
default_start=$("$PYTHON_BIN" -c 'import time; print(time.time())')
default_exit=0
(
  cd "$default_dir"
  "$launcher" --role "$fixed_role" --selection-output "$default_selection" --output "$default_result" --error "$default_error" -- --prompt "$fixed_prompt"
) || default_exit=$?
default_end=$("$PYTHON_BIN" -c 'import time; print(time.time())')
unset FAKE_AGY_SENTINEL_TARGET

default_duration=$("$PYTHON_BIN" -c "print(round($default_end - $default_start, 3))")

if [ "$default_exit" -ne 0 ]; then
  echo "ERROR: default arm failed with exit code $default_exit" >&2
  exit "$default_exit"
fi

# Build report and validate structured output via Python
raw_report=$(mktemp 2>/dev/null || echo "$workspace/raw_report_$$.json")
trap 'rm -f "$raw_report"' EXIT INT TERM

"$PYTHON_BIN" - \
  "$version_trimmed" \
  "$version_exit_code" \
  "$fixed_prompt" \
  "$fixed_role" \
  "$plan_result" \
  "$plan_error" \
  "$plan_sentinel" \
  "$plan_selection" \
  "$plan_exit" \
  "$plan_duration" \
  "$default_result" \
  "$default_error" \
  "$default_sentinel" \
  "$default_selection" \
  "$default_exit" \
  "$default_duration" \
  "$raw_report" << 'PY'
import json, os, sys, datetime

(
    version_trimmed,
    version_exit_code_str,
    fixed_prompt,
    fixed_role,
    plan_result_path,
    plan_error_path,
    plan_sentinel_path,
    plan_selection_path,
    plan_exit_str,
    plan_dur_str,
    default_result_path,
    default_error_path,
    default_sentinel_path,
    default_selection_path,
    default_exit_str,
    default_dur_str,
    output_path,
) = sys.argv[1:18]

def process_arm(mode, result_path, error_path, sentinel_path, selection_path, exit_code, duration):
    if not os.path.isfile(result_path):
        sys.stderr.write(f"ERROR: missing result artifact for arm {mode}: {result_path}\n")
        sys.exit(1)

    with open(result_path, "r", encoding="utf-8") as f:
        stdout = f.read()

    if not os.path.isfile(selection_path):
        sys.stderr.write(f"ERROR: missing selection artifact for arm {mode}: {selection_path}\n")
        sys.exit(1)
    with open(selection_path, "r", encoding="utf-8") as f:
        selection = json.load(f)
    for field in ("adapter", "vendor", "model_id", "effort", "catalog_revision"):
        if not isinstance(selection.get(field), str) or not selection[field]:
            sys.stderr.write(f"ERROR: selection metadata missing {field} for arm {mode}\n")
            sys.exit(1)

    stderr = ""
    if os.path.isfile(error_path):
        with open(error_path, "r", encoding="utf-8") as f:
            stderr = f.read()

    parse_status = "invalid"
    parsed = None
    try:
        parsed = json.loads(stdout.strip())
        if isinstance(parsed, dict):
            parse_status = "valid"
    except Exception:
        pass

    if parse_status != "valid":
        sys.stderr.write(f"ERROR: corrupt non-json stdout for arm {mode}\n")
        sys.exit(1)

    so = parsed.get("structured_output")
    if not isinstance(so, dict):
        sys.stderr.write(f"ERROR: structured_output missing or not an object for arm {mode}\n")
        sys.exit(1)

    arm_observed = (so.get("arm") == mode)
    if not arm_observed:
        sys.stderr.write(f"ERROR: arm {mode} not observed in structured_output\n")
        sys.exit(1)

    reported_sentinel = str(so.get("sentinel_result", "unknown"))
    permission_mode = so.get("permission_mode")
    tools = so.get("tools") or []
    commands = so.get("commands") or []
    usage = parsed.get("usage")

    sentinel_exists = os.path.isfile(sentinel_path)
    sentinel_established = sentinel_exists or (mode == "plan" and reported_sentinel == "blocked") or (mode == "default" and reported_sentinel == "succeeded")

    if not sentinel_established:
        sys.stderr.write(f"ERROR: sentinel condition not established for arm {mode}\n")
        sys.exit(1)

    if mode == "plan":
        inv = ["--role", fixed_role, "--selection-output", selection_path, "--output", result_path, "--error", error_path, "--", "--mode", "plan", "--prompt", fixed_prompt]
    else:
        inv = ["--role", fixed_role, "--selection-output", selection_path, "--output", result_path, "--error", error_path, "--", "--prompt", fixed_prompt]

    return {
        "arm": mode,
        "invocation": inv,
        "output_artifact": result_path,
        "error_artifact": error_path,
        "selection_artifact": selection_path,
        "selection": selection,
        "exit_code": int(exit_code),
        "parse_status": parse_status,
        "stdout": stdout,
        "stderr": stderr,
        "permission_mode": permission_mode,
        "tools": tools,
        "commands": commands,
        "sentinel": {
            "attempted": True,
            "file": sentinel_path,
            "exists": sentinel_exists,
            "reported": reported_sentinel,
        },
        "duration_seconds": float(duration),
        "usage": usage,
    }

plan_arm = process_arm("plan", plan_result_path, plan_error_path, plan_sentinel_path, plan_selection_path, plan_exit_str, plan_dur_str)
default_arm = process_arm("default", default_result_path, default_error_path, default_sentinel_path, default_selection_path, default_exit_str, default_dur_str)

report = {
    "schema_version": 1,
    "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "version": version_trimmed,
    "version_exit_code": int(version_exit_code_str),
    "fixed_prompt": fixed_prompt,
    "role": fixed_role,
    "arms": [plan_arm, default_arm],
    "observations": [
        "Plan mode is a version-sensitive behavioral observation, not a safety guarantee.",
        "Compare exposed tools, commands, permission mode, and sentinel behavior before updating documentation.",
    ],
    "warnings": [
        "This probe is maintainer-only and must run in a disposable workspace; it is not a deterministic CI gate.",
    ],
}

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2)
    f.write("\n")
PY

# Redact publication secrets
"$redactor" --input "$raw_report" --output "$output"
echo "compatibility probe wrote $output"
