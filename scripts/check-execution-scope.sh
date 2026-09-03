#!/usr/bin/env bash
# scripts/check-execution-scope.sh
# Platform-agnostic execution scope checker for Bash 3.2+.
# Verifies that touched files in the Git worktree are owned and not frozen.

set -euo pipefail

# 1. Validate that we are inside a Git worktree
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'Error: not inside a git worktree\n' >&2
  exit 1
fi

inside_worktree=$(git rev-parse --is-inside-work-tree 2>/dev/null || echo "false")
if [ "$inside_worktree" != "true" ]; then
  printf 'Error: not inside a git worktree\n' >&2
  exit 1
fi

# 2. Parse CLI arguments
raw_owned=()
raw_frozen=()
baseline=''
baseline_supplied=0

while [ $# -gt 0 ]; do
  case "$1" in
    --owned|-owned)
      if [ $# -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
        printf 'Error: --owned requires a value\n' >&2
        exit 1
      fi
      raw_owned+=("$2")
      shift 2
      ;;
    --owned=*|-owned=*)
      val="${1#*=}"
      if [ -z "$val" ]; then
        printf 'Error: --owned requires a value\n' >&2
        exit 1
      fi
      raw_owned+=("$val")
      shift 1
      ;;
    --frozen|-frozen)
      if [ $# -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
        printf 'Error: --frozen requires a value\n' >&2
        exit 1
      fi
      raw_frozen+=("$2")
      shift 2
      ;;
    --frozen=*|-frozen=*)
      val="${1#*=}"
      if [ -z "$val" ]; then
        printf 'Error: --frozen requires a value\n' >&2
        exit 1
      fi
      raw_frozen+=("$val")
      shift 1
      ;;
    --baseline|-baseline)
      if [ "$baseline_supplied" -eq 1 ] || [ $# -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
        printf 'Error: --baseline requires exactly one value\n' >&2
        exit 1
      fi
      baseline="$2"
      baseline_supplied=1
      shift 2
      ;;
    --baseline=*|-baseline=*)
      if [ "$baseline_supplied" -eq 1 ]; then
        printf 'Error: --baseline requires exactly one value\n' >&2
        exit 1
      fi
      val="${1#*=}"
      if [ -z "$val" ]; then
        printf 'Error: --baseline requires a value\n' >&2
        exit 1
      fi
      baseline="$val"
      baseline_supplied=1
      shift 1
      ;;
    -h|--help)
      printf 'Usage: %s --owned <path> [--owned <path> ...] [--frozen <path> ...] [--baseline <revision>]\n' "$0" >&2
      exit 0
      ;;
    *)
      printf 'Error: unrecognized argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [ "${#raw_owned[@]}" -eq 0 ]; then
  printf 'Error: at least one --owned path is required\n' >&2
  exit 1
fi

# 3. Path normalization helper
normalize_path() {
  local p="$1"
  p="${p//\\//}"
  while [[ "$p" == ./* ]]; do
    p="${p#./}"
  done
  while [[ "$p" == /* && "$p" != "/" ]]; do
    p="${p#/}"
  done
  while [[ "$p" == */ && "$p" != "/" ]]; do
    p="${p%/}"
  done
  if [[ "$p" == "." || "$p" == "/" ]]; then
    p=""
  fi
  printf '%s' "$p"
}

path_matches() {
  local candidate="$1"
  local target="$2"
  if [[ -z "$target" || "$target" == "." ]]; then
    return 0
  fi
  if [[ "$candidate" == "$target" ]]; then
    return 0
  fi
  if [[ "$candidate" == "$target/"* ]]; then
    return 0
  fi
  return 1
}

owned_targets=()
for o in "${raw_owned[@]}"; do
  owned_targets+=("$(normalize_path "$o")")
done

frozen_targets=()
if [ "${#raw_frozen[@]}" -gt 0 ]; then
  for f in "${raw_frozen[@]}"; do
    frozen_targets+=("$(normalize_path "$f")")
  done
fi

# 4. Discover touched files from Git
touched_paths=()

contains_element() {
  local elem="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$elem" ]]; then
      return 0
    fi
  done
  return 1
}

add_touched_path() {
  local path
  path="$(normalize_path "$1")"
  if [ -n "$path" ] && ! contains_element "$path" "${touched_paths[@]}"; then
    touched_paths+=("$path")
  fi
}

temp_root="${TMPDIR:-/tmp}"
status_file=$(mktemp "$temp_root/check-execution-scope.status.XXXXXX")
status_error_file=$(mktemp "$temp_root/check-execution-scope.status-error.XXXXXX")
baseline_file=$(mktemp "$temp_root/check-execution-scope.baseline.XXXXXX")
baseline_error_file=$(mktemp "$temp_root/check-execution-scope.baseline-error.XXXXXX")
diff_file=$(mktemp "$temp_root/check-execution-scope.diff.XXXXXX")
diff_error_file=$(mktemp "$temp_root/check-execution-scope.diff-error.XXXXXX")
cleanup() {
  rm -f "$status_file" "$status_error_file" "$baseline_file" "$baseline_error_file" "$diff_file" "$diff_error_file"
}
trap cleanup EXIT

run_git() {
  local output_file="$1"
  local error_file="$2"
  shift 2
  git "$@" >"$output_file" 2>"$error_file"
}

report_git_failure() {
  local operation="$1"
  local exit_code="$2"
  local error_file="$3"
  local detail=''
  if [ -f "$error_file" ]; then
    detail=$(<"$error_file")
  fi
  detail="${detail//$'\n'/ }"
  printf 'Error: git %s failed with exit code %s%s\n' "$operation" "$exit_code" "${detail:+: $detail}" >&2
}

if run_git "$status_file" "$status_error_file" -c core.quotepath=false status --porcelain=v1 -z -uall; then
  :
else
  exit_code=$?
  report_git_failure "status" "$exit_code" "$status_error_file"
  exit "$exit_code"
fi

while IFS= read -r -d '' entry; do
  [ -z "$entry" ] && continue
  if [ "${#entry}" -ge 3 ]; then
    code="${entry:0:2}"
    p1="${entry:3}"
    add_touched_path "$p1"
    if [[ "$code" == *R* || "$code" == *C* ]]; then
      IFS= read -r -d '' p2 || true
      if [ -n "$p2" ]; then
        add_touched_path "$p2"
      fi
    fi
  fi
done < "$status_file"

if [ "$baseline_supplied" -eq 1 ]; then
  if run_git "$baseline_file" "$baseline_error_file" rev-parse --verify "${baseline}^{commit}"; then
    :
  else
    exit_code=$?
    report_git_failure "baseline revision" "$exit_code" "$baseline_error_file"
    exit "$exit_code"
  fi
  resolved_baseline=$(tr -d '\r\n' < "$baseline_file")
  if [[ ! "$resolved_baseline" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
    printf 'Error: git baseline revision resolved to an invalid object id: %s\n' "$resolved_baseline" >&2
    exit 1
  fi

  if run_git "$diff_file" "$diff_error_file" -c core.quotepath=false diff --name-status -z --find-renames "$resolved_baseline"; then
    :
  else
    exit_code=$?
    report_git_failure "diff from baseline" "$exit_code" "$diff_error_file"
    exit "$exit_code"
  fi

  while IFS= read -r -d '' diff_code; do
    [ -z "$diff_code" ] && continue
    IFS= read -r -d '' diff_path || true
    if [ -z "$diff_path" ]; then
      printf 'Error: malformed NUL-delimited git diff output\n' >&2
      exit 1
    fi
    add_touched_path "$diff_path"
    if [[ "$diff_code" == R* || "$diff_code" == C* ]]; then
      IFS= read -r -d '' diff_old_path || true
      if [ -n "$diff_old_path" ]; then
        add_touched_path "$diff_old_path"
      fi
    fi
  done < "$diff_file"
fi

# 5. Check for ownership and frozen violations
violations=()

if [ "${#touched_paths[@]}" -gt 0 ]; then
  for p in "${touched_paths[@]}"; do
    # Check frozen
    is_frozen=0
    if [ "${#frozen_targets[@]}" -gt 0 ]; then
      for ft in "${frozen_targets[@]}"; do
        if path_matches "$p" "$ft"; then
          is_frozen=1
          break
        fi
      done
    fi

    if [ "$is_frozen" -eq 1 ]; then
      if [ "${#violations[@]}" -eq 0 ] || ! contains_element "$p" "${violations[@]}"; then
        violations+=("$p")
      fi
      continue
    fi

    # Check ownership
    is_owned=0
    if [ "${#owned_targets[@]}" -gt 0 ]; then
      for ot in "${owned_targets[@]}"; do
        if path_matches "$p" "$ot"; then
          is_owned=1
          break
        fi
      done
    fi

    if [ "$is_owned" -eq 0 ]; then
      if [ "${#violations[@]}" -eq 0 ] || ! contains_element "$p" "${violations[@]}"; then
        violations+=("$p")
      fi
    fi
  done
fi

if [ "${#violations[@]}" -gt 0 ]; then
  for v in "${violations[@]}"; do
    printf '%s\n' "$v"
  done
  exit 1
fi

exit 0
