#!/usr/bin/env bash
set -euo pipefail

validate_file=""
output_file=""
run_id=""
request_summary=""
selected_mode="web-research"
profile="standard"
deep_trigger=""
deep_trigger_set=0
start_time=""
end_time=""
duration_seconds=""
scratch_path=""
workers="[]"
snapshot_paths=()
snapshot_paths_json=""
final_citations="[]"
audit_verdicts="[]"
final_status=""
incomplete_stage_reasons="[]"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --validate|--check|-f|--input)
      validate_file="$2"
      shift 2
      ;;
    --output|-o)
      output_file="$2"
      shift 2
      ;;
    --run-id)
      run_id="$2"
      shift 2
      ;;
    --request-summary)
      request_summary="$2"
      shift 2
      ;;
    --selected-mode)
      selected_mode="$2"
      shift 2
      ;;
    --profile)
      profile="$2"
      shift 2
      ;;
    --deep-trigger)
      deep_trigger="$2"
      deep_trigger_set=1
      shift 2
      ;;
    --start-time)
      start_time="$2"
      shift 2
      ;;
    --end-time)
      end_time="$2"
      shift 2
      ;;
    --duration-seconds)
      duration_seconds="$2"
      shift 2
      ;;
    --scratch-path)
      scratch_path="$2"
      shift 2
      ;;
    --workers)
      workers="$2"
      shift 2
      ;;
    --snapshot-paths)
      snapshot_paths_json="$2"
      shift 2
      ;;
    --snapshot-path|--repo-path|--path)
      snapshot_paths+=("$2")
      shift 2
      ;;
    --final-citations)
      final_citations="$2"
      shift 2
      ;;
    --audit-verdicts)
      audit_verdicts="$2"
      shift 2
      ;;
    --final-status)
      final_status="$2"
      shift 2
      ;;
    --incomplete-stage-reasons)
      incomplete_stage_reasons="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: %s [--validate <file.json>] [build options] [--output <file.json>]\n' "$0" >&2
      exit 0
      ;;
    *)
      if [[ -z "$validate_file" && -f "$1" ]]; then
        validate_file="$1"
        shift
      else
        printf 'Error: unrecognized argument: %s\n' "$1" >&2
        exit 1
      fi
      ;;
  esac
done

# If snapshot_paths array was populated, convert to JSON array if snapshot_paths_json is empty
if [[ ${#snapshot_paths[@]} -gt 0 && -z "$snapshot_paths_json" ]]; then
  snapshot_paths_json=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1:]))" "${snapshot_paths[@]}")
fi

python3 - << 'PYEOF' \
  "$validate_file" \
  "$output_file" \
  "$run_id" \
  "$request_summary" \
  "$selected_mode" \
  "$profile" \
  "$deep_trigger" \
  "$deep_trigger_set" \
  "$start_time" \
  "$end_time" \
  "$duration_seconds" \
  "$scratch_path" \
  "$workers" \
  "$snapshot_paths_json" \
  "$final_citations" \
  "$audit_verdicts" \
  "$final_status" \
  "$incomplete_stage_reasons"
import sys
import json
import os

(
    val_file,
    out_file,
    r_id,
    req_summary,
    sel_mode,
    prof,
    d_trigger,
    d_trigger_set,
    s_time,
    e_time,
    dur_sec,
    s_path,
    w_json,
    snap_json,
    cits_json,
    verds_json,
    f_status,
    incomp_json,
) = sys.argv[1:19]

REQUIRED_FIELDS = [
    "run_id",
    "request_summary",
    "selected_mode",
    "profile",
    "deep_trigger",
    "start_time",
    "end_time",
    "duration_seconds",
    "scratch_path",
    "workers",
    "repository_snapshot_paths",
    "final_citations",
    "audit_verdicts",
    "final_status",
    "incomplete_stage_reasons"
]

def parse_json(raw, field_name, default_val):
    raw_str = raw.strip() if raw else ""
    if not raw_str:
        return default_val
    if os.path.exists(raw_str):
        try:
            with open(raw_str, "r", encoding="utf-8") as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError) as exc:
            sys.stderr.write(f"Error: failed to parse {field_name}: {exc}\n")
            sys.exit(1)
    try:
        return json.loads(raw_str)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"Error: failed to parse {field_name}: {exc}\n")
        sys.exit(1)

def require_list(data, field_name):
    if not isinstance(data, list):
        sys.stderr.write(f"Error: provenance field {field_name} must be an array\n")
        sys.exit(1)

data = None

if val_file:
    if val_file == "-":
        content = sys.stdin.read()
    else:
        if not os.path.exists(val_file):
            sys.stderr.write(f"Error: validation file does not exist: {val_file}\n")
            sys.exit(1)
        with open(val_file, "r", encoding="utf-8") as f:
            content = f.read()
    try:
        data = json.loads(content)
    except Exception as e:
        sys.stderr.write(f"Error: failed to parse JSON in {val_file}: {e}\n")
        sys.exit(1)
else:
    # Build from flags
    if not r_id or not req_summary or not s_time or not e_time or not dur_sec or not s_path or not f_status:
        missing = []
        if not r_id: missing.append("run_id")
        if not req_summary: missing.append("request_summary")
        if not s_time: missing.append("start_time")
        if not e_time: missing.append("end_time")
        if not dur_sec: missing.append("duration_seconds")
        if not s_path: missing.append("scratch_path")
        if not f_status: missing.append("final_status")
        sys.stderr.write(f"Error: missing mandatory build parameters: {', '.join(missing)}\n")
        sys.exit(1)

    try:
        dur_val = int(dur_sec) if dur_sec.isdigit() else float(dur_sec)
    except ValueError:
        dur_val = dur_sec

    trigger_val = None
    if d_trigger_set == "1" and d_trigger != "":
        trigger_val = d_trigger

    data = {
        "run_id": r_id,
        "request_summary": req_summary,
        "selected_mode": sel_mode,
        "profile": prof,
        "deep_trigger": trigger_val,
        "start_time": s_time,
        "end_time": e_time,
        "duration_seconds": dur_val,
        "scratch_path": s_path,
        "workers": parse_json(w_json, "workers", []),
        "repository_snapshot_paths": parse_json(snap_json, "repository_snapshot_paths", []),
        "final_citations": parse_json(cits_json, "final_citations", []),
        "audit_verdicts": parse_json(verds_json, "audit_verdicts", []),
        "final_status": f_status,
        "incomplete_stage_reasons": parse_json(incomp_json, "incomplete_stage_reasons", [])
    }

# Validate that all required fields are present
if not isinstance(data, dict):
    sys.stderr.write("Error: provenance record must be a JSON object\n")
    sys.exit(1)

missing_keys = [field for field in REQUIRED_FIELDS if field not in data]
if missing_keys:
    sys.stderr.write(f"Error: missing mandatory provenance fields: {', '.join(missing_keys)}\n")
    sys.exit(1)

if data["selected_mode"] not in {"execution", "repo-research", "web-research"}:
    sys.stderr.write("Error: selected_mode must be execution, repo-research, or web-research\n")
    sys.exit(1)
if data["profile"] not in {"standard", "deep"}:
    sys.stderr.write("Error: profile must be standard or deep\n")
    sys.exit(1)
if data["deep_trigger"] is not None and not isinstance(data["deep_trigger"], str):
    sys.stderr.write("Error: deep_trigger must be a string or null\n")
    sys.exit(1)
if not isinstance(data["duration_seconds"], (int, float)) or isinstance(data["duration_seconds"], bool) or data["duration_seconds"] < 0:
    sys.stderr.write("Error: duration_seconds must be a non-negative number\n")
    sys.exit(1)
if data["final_status"] not in {"success", "partial", "failed"}:
    sys.stderr.write("Error: final_status must be success, partial, or failed\n")
    sys.exit(1)
for field in ("workers", "repository_snapshot_paths", "final_citations", "audit_verdicts", "incomplete_stage_reasons"):
    require_list(data[field], field)

output_json = json.dumps(data, indent=2)

if out_file:
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(output_json + "\n")
else:
    sys.stdout.write(output_json + "\n")

PYEOF
