#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

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

output_json=$(python3 - << 'PYEOF' \
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
import re

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

REQUIRED_ATTEMPT_FIELDS = [
    "worker_id", "role", "mode", "attempt", "policy_revision",
    "route", "model", "effort", "reason", "started_at",
    "ended_at", "duration_seconds", "exit_code", "state",
    "failure_class", "evidence_paths", "usage"
]
KNOWN_ROLES = {"scout", "gate-author", "implementer", "reviewer", "researcher", "synthesizer", "auditor"}
KNOWN_MODES = {"execution", "repo-research", "web-research"}
KNOWN_ROUTES = {"default", "quality-retry"}
KNOWN_EFFORTS = {"low", "medium", "high"}
KNOWN_STATES = {"running", "completed", "failed", "interrupted"}
KNOWN_FAILURE_CLASSES = {"none", "quality", "timeout", "tool_error", "quota", "unrunnable", "unknown"}
KNOWN_VERIFICATION_STATUSES = {"pending", "passed", "failed", "not_performed"}
GEMINI_MODEL_RE = re.compile(r"^gemini-[a-zA-Z0-9.-]+-(low|medium|high)$")

def validate_worker_routing(worker):
    if not isinstance(worker, dict):
        sys.stderr.write("Error: worker entry must be a JSON object\n")
        sys.exit(1)
    if "routing" not in worker or worker["routing"] is None:
        return
    routing = worker["routing"]
    if not isinstance(routing, dict):
        sys.stderr.write("Error: worker routing must be a JSON object\n")
        sys.exit(1)
    if "schema_version" not in routing or not isinstance(routing["schema_version"], int) or isinstance(routing["schema_version"], bool) or routing["schema_version"] != 1:
        sys.stderr.write("Error: routing schema_version must be integer 1\n")
        sys.exit(1)
    if "attempts" not in routing or not isinstance(routing["attempts"], list):
        sys.stderr.write("Error: routing attempts must be an array\n")
        sys.exit(1)
    seen_attempt_pairs = set()
    attempt_counts = {}
    for att in routing["attempts"]:
        if not isinstance(att, dict):
            sys.stderr.write("Error: routing attempt must be a JSON object\n")
            sys.exit(1)
        for req_field in REQUIRED_ATTEMPT_FIELDS:
            if req_field not in att:
                sys.stderr.write(f"Error: routing attempt missing required field: {req_field}\n")
                sys.exit(1)
        if "verification_status" not in att and "verification" not in att:
            sys.stderr.write("Error: routing attempt missing verification_status or verification field\n")
            sys.exit(1)
        if not isinstance(att["worker_id"], str) or not att["worker_id"].strip():
            sys.stderr.write("Error: attempt worker_id must be a non-empty string\n")
            sys.exit(1)
        if att["role"] not in KNOWN_ROLES:
            sys.stderr.write(f"Error: attempt role must be one of: {', '.join(sorted(KNOWN_ROLES))}\n")
            sys.exit(1)
        if att["mode"] not in KNOWN_MODES:
            sys.stderr.write(f"Error: attempt mode must be one of: {', '.join(sorted(KNOWN_MODES))}\n")
            sys.exit(1)
        if not isinstance(att["attempt"], int) or isinstance(att["attempt"], bool) or att["attempt"] not in (1, 2):
            sys.stderr.write("Error: attempt number must be integer 1 or 2\n")
            sys.exit(1)
        attempt_key = (att["worker_id"], att["attempt"])
        if attempt_key in seen_attempt_pairs:
            sys.stderr.write("Error: duplicate worker_id/attempt pair in routing attempts\n")
            sys.exit(1)
        seen_attempt_pairs.add(attempt_key)
        attempt_counts[att["worker_id"]] = attempt_counts.get(att["worker_id"], 0) + 1
        if attempt_counts[att["worker_id"]] > 2:
            sys.stderr.write(f"Error: routing attempts cannot contain more than 2 attempts for worker '{att['worker_id']}'\n")
            sys.exit(1)
        if not isinstance(att["policy_revision"], str) or not att["policy_revision"].strip():
            sys.stderr.write("Error: attempt policy_revision must be a non-empty string\n")
            sys.exit(1)
        if att["route"] not in KNOWN_ROUTES:
            sys.stderr.write("Error: attempt route must be 'default' or 'quality-retry'\n")
            sys.exit(1)
        if not isinstance(att["model"], str) or not GEMINI_MODEL_RE.match(att["model"]):
            sys.stderr.write("Error: attempt model must be a Gemini model ID with effort suffix\n")
            sys.exit(1)
        if att["effort"] not in KNOWN_EFFORTS:
            sys.stderr.write("Error: attempt effort must be 'low', 'medium', or 'high'\n")
            sys.exit(1)
        if not att["model"].endswith(f"-{att['effort']}"):
            sys.stderr.write(f"Error: attempt effort '{att['effort']}' does not match model suffix in '{att['model']}'\n")
            sys.exit(1)
        if not isinstance(att["reason"], str) or not att["reason"].strip():
            sys.stderr.write("Error: attempt reason must be a non-empty string\n")
            sys.exit(1)
        if not isinstance(att["started_at"], str) or not att["started_at"].strip():
            sys.stderr.write("Error: attempt started_at must be a non-empty string timestamp\n")
            sys.exit(1)
        if att["ended_at"] is not None and (not isinstance(att["ended_at"], str) or not att["ended_at"].strip()):
            sys.stderr.write("Error: attempt ended_at must be a non-empty string timestamp or null\n")
            sys.exit(1)
        if att["duration_seconds"] is not None:
            if not isinstance(att["duration_seconds"], (int, float)) or isinstance(att["duration_seconds"], bool) or att["duration_seconds"] < 0:
                sys.stderr.write("Error: attempt duration_seconds must be a non-negative number or null\n")
                sys.exit(1)
        if att["exit_code"] is not None:
            if not isinstance(att["exit_code"], int) or isinstance(att["exit_code"], bool):
                sys.stderr.write("Error: attempt exit_code must be an integer or null\n")
                sys.exit(1)
        if att["state"] not in KNOWN_STATES:
            sys.stderr.write(f"Error: attempt state must be one of: {', '.join(sorted(KNOWN_STATES))}\n")
            sys.exit(1)
        if att["failure_class"] not in KNOWN_FAILURE_CLASSES:
            sys.stderr.write(f"Error: attempt failure_class must be one of: {', '.join(sorted(KNOWN_FAILURE_CLASSES))}\n")
            sys.exit(1)
        v_val = att["verification_status"] if "verification_status" in att else att["verification"]
        if v_val not in KNOWN_VERIFICATION_STATUSES:
            sys.stderr.write(f"Error: attempt verification_status must be one of: {', '.join(sorted(KNOWN_VERIFICATION_STATUSES))}\n")
            sys.exit(1)
        if not isinstance(att["evidence_paths"], list) or not all(isinstance(p, str) for p in att["evidence_paths"]):
            sys.stderr.write("Error: attempt evidence_paths must be an array of strings\n")
            sys.exit(1)
        if att["usage"] is not None and not isinstance(att["usage"], dict):
            sys.stderr.write("Error: attempt usage must be null or a JSON object with explicit units\n")
            sys.exit(1)

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

for w in data["workers"]:
    validate_worker_routing(w)

output_json = json.dumps(data, indent=2)
print(output_json)
PYEOF
)

raw_tmp=$(mktemp)
public_tmp=$(mktemp)
trap 'rm -f "$raw_tmp" "$public_tmp"' EXIT
printf '%s\n' "$output_json" > "$raw_tmp"
"$script_dir/redact-publication-secrets.sh" --input "$raw_tmp" --output "$public_tmp"
if [[ -n "$output_file" ]]; then
  mkdir -p "$(dirname "$output_file")"
  cp "$public_tmp" "$output_file"
else
  cat "$public_tmp"
fi
