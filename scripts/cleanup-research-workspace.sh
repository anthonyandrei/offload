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

# For success, preserve only final.md, provenance.json, and .offload-research-workspace
if [[ "$status" == "success" ]]; then
  shopt -s nullglob dotglob
  for entry in "$target_phys"/*; do
    base=$(basename "$entry")
    case "$base" in
      '.'|'..')
        ;;
      'final.md'|'provenance.json'|'.offload-research-workspace')
        ;;
      *)
        rm -rf "$entry"
        ;;
    esac
  done
  shopt -u nullglob dotglob
fi
