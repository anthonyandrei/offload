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
    -h|--help)
      printf 'Usage: %s --owned <path> [--owned <path> ...] [--frozen <path> ...]\n' "$0" >&2
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

while IFS= read -r -d '' entry; do
  [ -z "$entry" ] && continue
  if [ "${#entry}" -ge 3 ]; then
    code="${entry:0:2}"
    p1="${entry:3}"
    touched_paths+=("$p1")
    if [[ "$code" == *R* || "$code" == *C* ]]; then
      IFS= read -r -d '' p2 || true
      if [ -n "$p2" ]; then
        touched_paths+=("$p2")
      fi
    fi
  fi
done < <(git -c core.quotepath=false status --porcelain=v1 -z -uall)

# 5. Check for ownership and frozen violations
violations=()

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
