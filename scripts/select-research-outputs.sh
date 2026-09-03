#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: select-research-outputs.sh --workers FILE [--base-dir DIRECTORY]

Selects completed, verified researcher artifacts from an explicit worker manifest.
The manifest may be a workers array or an object containing a workers array.
EOF
}

workers_file=''
base_dir=$(pwd)

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workers)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      workers_file=$2
      shift 2
      ;;
    --base-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      base_dir=$2
      shift 2
      ;;
    --help|-h)
      usage >&1
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$workers_file" ] || { usage; exit 2; }
[ -f "$workers_file" ] || { printf 'select-research-outputs: worker manifest does not exist: %s\n' "$workers_file" >&2; exit 2; }
[ -d "$base_dir" ] || { printf 'select-research-outputs: base directory does not exist: %s\n' "$base_dir" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'select-research-outputs: jq is required\n' >&2; exit 2; }

workers_json=$(jq -ce '
  if type == "array" then .
  elif type == "object" and (.workers | type) == "array" then .workers
  else error("expected a workers array or an object containing workers")
  end
' "$workers_file") || {
  printf 'select-research-outputs: invalid worker manifest\n' >&2
  exit 2
}

selection_json='{"selected_files":[],"independent_angles":[],"omitted_workers":[]}'

omit_worker() {
  local worker_id=$1
  local reason=$2
  selection_json=$(jq -c --arg worker_id "$worker_id" --arg reason "$reason" \
    '.omitted_workers += [{worker_id: $worker_id, reason: $reason}]' <<<"$selection_json")
}

worker_count=$(jq 'length' <<<"$workers_json")
index=0
while [ "$index" -lt "$worker_count" ]; do
  worker=$(jq -c ".[$index]" <<<"$workers_json")
  worker_id=$(jq -r '.id // .worker_id // "<unknown>"' <<<"$worker")

  if [ "$(jq -r '.role // empty' <<<"$worker")" != 'researcher' ]; then
    index=$((index + 1))
    continue
  fi
  if [ "$(jq -r '.status // empty' <<<"$worker")" != 'completed' ]; then
    omit_worker "$worker_id" 'worker is not completed'
    index=$((index + 1))
    continue
  fi
  if ! jq -e '(.accepted_attempt | type) == "number" and (.accepted_attempt == (.accepted_attempt | floor)) and (.accepted_attempt == 1 or .accepted_attempt == 2)' <<<"$worker" >/dev/null; then
    omit_worker "$worker_id" 'accepted_attempt is missing or outside the two-attempt ceiling'
    index=$((index + 1))
    continue
  fi
  accepted_attempt=$(jq -r '.accepted_attempt' <<<"$worker")
  output=$(jq -r '.output // empty' <<<"$worker")
  if [ -z "$output" ]; then
    omit_worker "$worker_id" 'selected output path is missing'
    index=$((index + 1))
    continue
  fi
  if ! jq -e '.routing.schema_version == 1 and (.routing.attempts | type) == "array"' <<<"$worker" >/dev/null; then
    omit_worker "$worker_id" 'routing attempts are missing the versioned container'
    index=$((index + 1))
    continue
  fi

  attempt_json=$(jq -c --argjson accepted "$accepted_attempt" --arg output "$output" '
    [.routing.attempts[]?
      | select(.attempt == $accepted)
      | select(.state == "completed" and .verification_status == "passed" and .exit_code == 0)
      | select((.evidence_paths | type) == "array" and .evidence_paths[0] == $output)]
  ' <<<"$worker")
  if [ "$(jq 'length' <<<"$attempt_json")" -ne 1 ]; then
    omit_worker "$worker_id" 'accepted attempt is not a uniquely completed, verified attempt'
    index=$((index + 1))
    continue
  fi

  case "$output" in
    /*) selected_path=$output ;;
    *) selected_path=$base_dir/$output ;;
  esac
  if [ ! -f "$selected_path" ]; then
    omit_worker "$worker_id" 'selected output artifact does not exist'
    index=$((index + 1))
    continue
  fi
  artifact_path=$selected_path
  if command -v cygpath >/dev/null 2>&1; then
    artifact_path=$(cygpath -w "$selected_path")
  fi
  if ! jq -e '
    type == "object"
    and (.structured_output | type) == "object"
    and .structured_output.status == "success"
    and (.structured_output.angle_id | type) == "string"
    and (.structured_output.angle_id | length) > 0
  ' "$artifact_path" >/dev/null 2>&1; then
    omit_worker "$worker_id" 'selected artifact is not a successful researcher result'
    index=$((index + 1))
    continue
  fi

  angle_id=$(jq -r '.structured_output.angle_id' "$artifact_path")
  selection_json=$(MSYS_NO_PATHCONV=1 jq -c --arg path "$selected_path" --arg angle "$angle_id" \
    '.selected_files += [$path] | .independent_angles += [$angle]' <<<"$selection_json")
  index=$((index + 1))
done

jq -c '.independent_angles |= unique | .independent_angle_count = (.independent_angles | length)' <<<"$selection_json"
