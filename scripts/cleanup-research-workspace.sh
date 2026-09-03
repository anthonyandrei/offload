#!/usr/bin/env bash
set -euo pipefail

workspace=""
status=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      workspace="$2"
      shift 2
      ;;
    --status)
      status="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: %s --workspace <path> --status <success|partial|failed>\n' "$0" >&2
      exit 0
      ;;
    *)
      printf 'Error: unrecognized argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$workspace" || -z "$status" ]]; then
  printf 'Error: --workspace and --status are required\n' >&2
  exit 1
fi

case "$status" in
  success|partial|failed)
    ;;
  *)
    printf 'Error: invalid status: %s (must be success, partial, or failed)\n' "$status" >&2
    exit 1
    ;;
esac

if [[ ! -d "$workspace" ]]; then
  printf 'Error: workspace directory does not exist: %s\n' "$workspace" >&2
  exit 1
fi

# Reject process current directory before changing directories
cwd_phys=$(pwd -P)
target_phys=$(cd "$workspace" 2>/dev/null && pwd -P)

if [[ -z "$target_phys" || ! -d "$target_phys" ]]; then
  printf 'Error: failed to resolve workspace path: %s\n' "$workspace" >&2
  exit 1
fi

if [[ "$target_phys" == "$cwd_phys" ]]; then
  printf 'Error: refusing to clean process current directory: %s\n' "$workspace" >&2
  exit 1
fi

# Reject filesystem root
if [[ "$target_phys" == "/" ]] || [[ "$target_phys" =~ ^/[a-zA-Z]?$ ]] || [[ "$target_phys" =~ ^[a-zA-Z]:[/\\]?$ ]]; then
  printf 'Error: refusing to clean filesystem root: %s\n' "$target_phys" >&2
  exit 1
fi

# Reject user home directory
if [[ -n "${HOME:-}" && -d "$HOME" ]]; then
  home_phys=$(cd "$HOME" 2>/dev/null && pwd -P)
  if [[ -n "$home_phys" && "$target_phys" == "$home_phys" ]]; then
    printf 'Error: refusing to clean user home directory: %s\n' "$target_phys" >&2
    exit 1
  fi
fi

if [[ -n "${USERPROFILE:-}" && -d "$USERPROFILE" ]]; then
  profile_phys=$(cd "$USERPROFILE" 2>/dev/null && pwd -P)
  if [[ -n "$profile_phys" && "$target_phys" == "$profile_phys" ]]; then
    printf 'Error: refusing to clean user profile directory: %s\n' "$target_phys" >&2
    exit 1
  fi
fi

# Reject Git worktree root
if [[ -e "$target_phys/.git" ]]; then
  printf 'Error: refusing to clean Git worktree root: %s\n' "$target_phys" >&2
  exit 1
fi

if git -C "$target_phys" rev-parse --show-toplevel >/dev/null 2>&1; then
  git_toplevel=$(cd "$(git -C "$target_phys" rev-parse --show-toplevel)" 2>/dev/null && pwd -P)
  if [[ "$git_toplevel" == "$target_phys" ]]; then
    printf 'Error: refusing to clean Git worktree root: %s\n' "$target_phys" >&2
    exit 1
  fi
fi

# Reject directory without .offload-research-workspace containing exact version marker
marker_file="$target_phys/.offload-research-workspace"
if [[ ! -f "$marker_file" ]]; then
  printf 'Error: missing workspace marker file in %s\n' "$target_phys" >&2
  exit 1
fi

marker_content=$(cat "$marker_file" 2>/dev/null || true)
if [[ "$marker_content" != "offload-research-workspace-v1" ]]; then
  printf 'Error: invalid workspace marker content in %s\n' "$marker_file" >&2
  exit 1
fi

marker_last_byte=$(tail -c 1 "$marker_file" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')
if [[ "$marker_last_byte" != "0a" ]]; then
  printf 'Error: workspace marker missing trailing newline: %s\n' "$marker_file" >&2
  exit 1
fi

# For partial and failed, all validation passed, preserve all contents
if [[ "$status" == "partial" || "$status" == "failed" ]]; then
  exit 0
fi

routing_file="$target_phys/routing-outcomes.json"
disposition_file="$target_phys/evidence-disposition.json"
retained_names='final.md provenance.json routing-outcomes.json evidence-disposition.json .offload-research-workspace'

cleanup_tmp=$(mktemp -d "${TMPDIR:-/tmp}/offload-cleanup.XXXXXX")
trap 'rm -rf "$cleanup_tmp"' EXIT

fail_cleanup() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

validate_routing_record() {
  if [[ ! -f "$routing_file" || -L "$routing_file" ]]; then
    fail_cleanup 'routing record must be a regular file'
  fi

  if ! jq -e '
    def string_field($name): (.[$name] | type == "string" and length > 0);
    def nullable_string_field($name): ((.[$name] == null) or (.[$name] | type == "string" and length > 0));
    type == "object"
    and (.schema_version | type == "number" and . == 1)
    and (.attempts | type == "array" and length <= 2)
    and ((.attempts | map(.attempt)) as $numbers
         | (($numbers | unique | length) == ($numbers | length)))
    and all(.attempts[];
      type == "object"
      and string_field("worker_id")
      and (.role | IN("scout", "gate-author", "implementer", "reviewer", "researcher", "synthesizer", "auditor"))
      and (.mode | IN("execution", "repo-research", "web-research"))
      and string_field("policy_revision")
      and (.route | IN("default", "quality-retry"))
      and string_field("model")
      and (.effort | IN("low", "medium", "high"))
      and (.model | test("^gemini-[a-zA-Z0-9.-]+-(low|medium|high)$"))
      and ((.model as $model | .effort as $effort | $model | endswith("-" + $effort)))
      and string_field("reason")
      and (.state | IN("running", "completed", "failed", "interrupted"))
      and string_field("started_at")
      and nullable_string_field("ended_at")
      and (.attempt | type == "number" and floor == . and . >= 1 and . <= 2)
      and ((.duration_seconds == null) or (.duration_seconds | type == "number" and . >= 0))
      and ((.exit_code == null) or (.exit_code | type == "number" and floor == .))
      and (.failure_class | IN("none", "quality", "timeout", "tool_error", "quota", "unknown"))
      and ((.verification_status? // .verification?) | IN("pending", "passed", "failed", "not_performed"))
      and (.evidence_paths | type == "array" and all(.[]; type == "string"))
      and ((.usage == null) or (.usage | type == "object"))
    )
  ' "$routing_file" >/dev/null 2>&1; then
    fail_cleanup "invalid routing record: $routing_file"
  fi
}

hash_regular_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    return 1
  fi
}

evidence_exists_json=null
evidence_sha256=''
evidence_disposition=''
evidence_reason=''
get_evidence_disposition() {
  local relative_path="$1"
  evidence_exists_json=null
  evidence_sha256=''
  evidence_disposition=''
  evidence_reason=''

  if [[ -z "$relative_path" || "$relative_path" == /* || "$relative_path" == [A-Za-z]:* || "$relative_path" == *:* || "$relative_path" == *$'\n'* || "$relative_path" == *$'\r'* ]]; then
    evidence_disposition='uninspected'
    evidence_reason='path is not a safe relative workspace path'
    return
  fi

  local normalized="${relative_path//\\//}"
  local old_ifs="$IFS"
  IFS=/ read -r -a path_parts <<< "$normalized"
  IFS="$old_ifs"
  if [[ ${#path_parts[@]} -eq 0 ]]; then
    evidence_disposition='uninspected'
    evidence_reason='path contains unsafe traversal components'
    return
  fi

  local candidate="$target_phys"
  local part
  for part in "${path_parts[@]}"; do
    if [[ -z "$part" || "$part" == '.' || "$part" == '..' ]]; then
      evidence_disposition='uninspected'
      evidence_reason='path contains unsafe traversal components'
      return
    fi
    candidate="$candidate/$part"
    if [[ -L "$candidate" ]]; then
      evidence_exists_json=true
      evidence_disposition='uninspected'
      evidence_reason='path contains a symbolic link or reparse point'
      return
    fi
    if [[ -e "$candidate" ]]; then
      evidence_exists_json=true
    else
      evidence_exists_json=false
      evidence_disposition='missing'
      return
    fi
  done

  if [[ ! -f "$candidate" ]]; then
    evidence_disposition='uninspected'
    evidence_reason='path is not a regular file'
    return
  fi
  evidence_sha256=$(hash_regular_file "$candidate") || fail_cleanup 'no SHA-256 implementation is available'
  case "${normalized}" in
    final.md|provenance.json|routing-outcomes.json|evidence-disposition.json|.offload-research-workspace)
      evidence_disposition='retained'
      ;;
    *)
      evidence_disposition='pruned'
      ;;
  esac
}

append_disposition_entry() {
  local relative_path="$1"
  local reason_json=null
  if [[ -n "$evidence_reason" ]]; then
    reason_json=$(jq -n --arg reason "$evidence_reason" '$reason')
  fi
  entries_json=$(jq \
    --arg path "$relative_path" \
    --argjson exists "$evidence_exists_json" \
    --arg sha256 "$evidence_sha256" \
    --arg disposition "$evidence_disposition" \
    --argjson reason "$reason_json" \
    '. + [{path: $path, exists_before_cleanup: $exists, sha256: (if $sha256 == "" then null else $sha256 end), disposition: $disposition, status: $disposition, reason: $reason}]' \
    <<< "$entries_json") || fail_cleanup 'could not build evidence disposition manifest'
}

write_evidence_disposition() {
  if [[ -e "$routing_file" || -L "$routing_file" ]]; then
    validate_routing_record
  fi

  if [[ -L "$disposition_file" || -e "$disposition_file" ]]; then
    if [[ ! -f "$disposition_file" || -L "$disposition_file" ]] || ! jq -e 'type == "object" and .schema_version == 1 and (.entries | type == "array")' "$disposition_file" >/dev/null 2>&1; then
      fail_cleanup "existing evidence disposition manifest is invalid: $disposition_file"
    fi
    return
  fi

  paths_file="$cleanup_tmp/evidence-paths"
  entries_json='[]'
  : > "$paths_file"
  if [[ -e "$routing_file" || -L "$routing_file" ]]; then
    jq -r '.attempts[]?.evidence_paths[]?' "$routing_file" > "$paths_file" || fail_cleanup "could not read evidence paths: $routing_file"
  fi

  local evidence_path
  while IFS= read -r evidence_path || [[ -n "$evidence_path" ]]; do
    evidence_path="${evidence_path%$'\r'}"
    get_evidence_disposition "$evidence_path"
    append_disposition_entry "$evidence_path"
  done < "$paths_file"

  manifest_tmp="$cleanup_tmp/evidence-disposition.json"
  jq -n --arg routing_record 'routing-outcomes.json' --argjson entries "$entries_json" \
    '{schema_version: 1, routing_record: $routing_record, entries: $entries}' > "$manifest_tmp" || fail_cleanup "could not write evidence disposition manifest: $disposition_file"
  mv -- "$manifest_tmp" "$disposition_file" || fail_cleanup "could not retain evidence disposition manifest: $disposition_file"
}

remove_entry_without_following_link() {
  local entry="$1"
  if [[ -L "$entry" ]]; then
    rm -f -- "$entry"
  elif [[ -d "$entry" ]]; then
    local child
    shopt -s nullglob dotglob
    for child in "$entry"/*; do
      remove_entry_without_following_link "$child"
    done
    shopt -u nullglob dotglob
    rmdir -- "$entry"
  else
    rm -f -- "$entry"
  fi
}

# For success, retain final.md, provenance.json, routing outcomes, disposition, and the marker.
if [[ "$status" == "success" ]]; then
  write_evidence_disposition
  shopt -s nullglob dotglob
  for entry in "$target_phys"/*; do
    base=$(basename "$entry")
    case " $retained_names " in
      *" $base "*)
        ;;
      *)
        remove_entry_without_following_link "$entry"
        ;;
    esac
  done
  shopt -u nullglob dotglob
fi
