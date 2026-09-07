#!/usr/bin/env bash
set -euo pipefail

marker_name='.offload-research-workspace'
marker_content='offload-research-workspace-v2'

fail() {
  local code=1
  if (($# > 1)); then
    code=$2
  fi
  printf 'Error: %s\n' "$1" >&2
  exit "$code"
}

canonical_existing_path() {
  [[ -d "$1" ]] || fail "directory does not exist: $1"
  (CDPATH= cd -P -- "$1" && pwd -P)
}

remove_tree_safely() {
  local path=$1
  local entry
  while IFS= read -r -d '' entry; do
    if [[ -L "$entry" || ! -d "$entry" ]]; then
      rm -f -- "$entry"
    else
      remove_tree_safely "$entry"
    fi
  done < <(find -P "$path" -mindepth 1 -maxdepth 1 -print0)
  rmdir -- "$path"
}

show_usage() {
  cat >&2 <<'USAGE'
Usage:
  cleanup-research-workspace.sh --workspace <path> [--retain]

Only a marked disposable snapshot can be removed. Links are removed as links
and are never traversed.
USAGE
}

[[ "${OFFLOAD_WORKER_CONTEXT:-}" != 1 ]] || fail 'worker context cannot remove a research snapshot' 126

workspace=''
retain=0
while (($#)); do
  case "$1" in
    --workspace)
      (($# > 1)) || fail '--workspace requires a path'
      workspace=$2
      shift 2
      ;;
    --workspace=*)
      workspace=${1#*=}
      shift
      ;;
    --retain)
      retain=1
      shift
      ;;
    --help|-h)
      show_usage
      exit 0
      ;;
    *)
      fail "unrecognized argument: $1"
      ;;
  esac
done

[[ -n "$workspace" ]] || fail '--workspace is required'
[[ ! -L "$workspace" ]] || fail "refusing to clean a symlink: $workspace"
workspace=$(canonical_existing_path "$workspace")
[[ "$workspace" != '/' ]] || fail "refusing to clean a filesystem root: $workspace"
cwd=$(CDPATH= cd -P -- "$PWD" && pwd -P)
[[ "$workspace" != "$cwd" ]] || fail "refusing to clean the current directory: $workspace"
if [[ -n "${HOME:-}" && -d "$HOME" ]]; then
  home=$(CDPATH= cd -P -- "$HOME" && pwd -P)
  [[ "$workspace" != "$home" ]] || fail "refusing to clean a user home directory: $workspace"
fi
marker="$workspace/$marker_name"
[[ -f "$marker" ]] || fail "refusing to clean an unmarked directory: $workspace"
[[ "$(<"$marker")" = "$marker_content" ]] || fail "refusing to clean a directory with an invalid marker: $workspace"
[[ ! -e "$workspace/.git" ]] || fail "refusing to clean a Git checkout: $workspace"

if ((retain)); then
  printf 'Retained research workspace: %s\n' "$workspace"
  exit 0
fi

remove_tree_safely "$workspace"
printf 'Removed research workspace: %s\n' "$workspace"
