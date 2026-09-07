#!/usr/bin/env bash
set -euo pipefail

marker_name='.offload-execution-workspace'
marker_content='offload-execution-workspace-v2'
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
scope_checker="$script_dir/check-execution-scope.sh"

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

canonical_workspace_path() {
  local raw=$1
  local absolute parent name
  if [[ "$raw" = /* ]]; then
    absolute=$raw
  else
    absolute="$PWD/$raw"
  fi
  parent=$(dirname -- "$absolute")
  name=$(basename -- "$absolute")
  [[ -d "$parent" ]] || fail "workspace parent directory does not exist: $parent"
  printf '%s/%s\n' "$(CDPATH= cd -P -- "$parent" && pwd -P)" "$name"
}

path_is_within() {
  local child=$1
  local parent=$2
  [[ "$child" = "$parent" || "$child" = "$parent"/* ]]
}

same_path() {
  [[ "$1" = "$2" ]]
}

canonical_compare_path() {
  local path=$1
  if command -v cygpath >/dev/null 2>&1; then
    path=$(cygpath -w "$path")
  fi
  canonical_existing_path "$path"
}

require_git_repo() {
  local requested=$1
  local root
  root=$(canonical_existing_path "$requested")
  git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1 || fail "not a Git repository: $root"
  canonical_existing_path "$(git -C "$root" rev-parse --show-toplevel)"
}

resolve_commit() {
  local repo=$1
  local revision=$2
  [[ -n "$revision" ]] || fail 'baseline is required'
  git -C "$repo" rev-parse --verify "$revision^{commit}" 2>/dev/null || fail "baseline does not resolve to a commit: $revision"
}

check_safe_workspace_path() {
  local workspace=$1
  local source=${2:-}
  [[ -n "$workspace" ]] || fail 'workspace path is empty'
  [[ "$workspace" != '/' ]] || fail "refusing to use a filesystem root as a workspace: $workspace"
  local cwd
  cwd=$(CDPATH= cd -P -- "$PWD" && pwd -P)
  same_path "$workspace" "$cwd" && fail "refusing to use the current directory as a workspace: $workspace"
  if [[ -n "${HOME:-}" && -d "$HOME" ]]; then
    local home
    home=$(CDPATH= cd -P -- "$HOME" && pwd -P)
    same_path "$workspace" "$home" && fail "refusing to use a user home directory as a workspace: $workspace"
  fi
  if [[ -n "$source" ]] && path_is_within "$workspace" "$source"; then
    fail "workspace must be outside the source repository: $workspace"
  fi
}

read_marker() {
  local workspace=$1
  local marker="$workspace/$marker_name"
  [[ -f "$marker" ]] || fail "workspace is not marked as disposable: $workspace"
  local content
  content=$(<"$marker")
  [[ "$content" = "$marker_content" ]] || fail "workspace marker is invalid: $workspace"
}

require_registered_worktree() {
  local source=$1
  local workspace=$2
  local canonical_workspace
  canonical_workspace=$(canonical_compare_path "$workspace")
  local line
  local found=1
  while IFS= read -r line; do
    if [[ "$line" = 'worktree '* ]]; then
      local path=${line#worktree }
      if [[ "$(canonical_compare_path "$path")" = "$canonical_workspace" ]]; then
        found=0
        break
      fi
    fi
  done < <(git -C "$source" worktree list --porcelain)
  ((found == 0)) || fail "workspace is not registered with the source repository: $workspace"
}

remove_empty_generated_parent() {
  local workspace=$1
  local parent
  parent=$(dirname -- "$workspace")
  [[ "$(basename -- "$parent")" = offload-exec-* ]] || return 0
  rmdir -- "$parent" 2>/dev/null || true
}

show_usage() {
  cat >&2 <<'USAGE'
Usage:
  execution-workspace.sh create --source-repo <path> --task-id <id> --baseline <revision> [--workspace <path>]
  execution-workspace.sh check --workspace <path> --baseline <revision> --owned <path> [--owned <path> ...] [--frozen <path> ...]
  execution-workspace.sh cleanup --source-repo <path> --workspace <path> [--retain]

The create command makes a marked detached Git worktree. The check command
delegates final scope inspection to the generic scope checker. The cleanup
command removes only a marked worktree registered with the source repository.
USAGE
}

command=${1:-}
shift || true

case "$command" in
  create)
    source=''
    task_id=''
    baseline=''
    workspace=''
    while (($#)); do
      case "$1" in
        --source-repo)
          (($# > 1)) || fail '--source-repo requires a path'
          source=$2
          shift 2
          ;;
        --source-repo=*)
          source=$(printf '%s' "$1" | cut -d= -f2-)
          shift
          ;;
        --task-id)
          (($# > 1)) || fail '--task-id requires a value'
          task_id=$2
          shift 2
          ;;
        --task-id=*)
          task_id=$(printf '%s' "$1" | cut -d= -f2-)
          shift
          ;;
        --baseline)
          (($# > 1)) || fail '--baseline requires a revision'
          baseline=$2
          shift 2
          ;;
        --baseline=*)
          baseline=$(printf '%s' "$1" | cut -d= -f2-)
          shift
          ;;
        --workspace)
          (($# > 1)) || fail '--workspace requires a path'
          workspace=$2
          shift 2
          ;;
        --workspace=*)
          workspace=$(printf '%s' "$1" | cut -d= -f2-)
          shift
          ;;
        --help|-h)
          show_usage
          exit 0
          ;;
        *)
          fail "unrecognized argument for create: $1"
          ;;
      esac
    done

    [[ "${OFFLOAD_WORKER_CONTEXT:-}" != 1 ]] || fail 'worker context cannot create or mutate an execution workspace' 126
    [[ -n "$source" ]] || fail '--source-repo is required'
    [[ "$task_id" =~ ^[A-Za-z0-9._-]+$ ]] || fail '--task-id must contain only letters, numbers, dots, underscores, and hyphens'
    source_path=$(require_git_repo "$source")
    baseline_commit=$(resolve_commit "$source_path" "$baseline")

    if [[ -z "$workspace" ]]; then
      temp_parent=$(mktemp -d "${TMPDIR:-/tmp}/offload-exec-${task_id}-XXXXXX") || fail 'could not create a temporary workspace parent'
      workspace="$temp_parent/checkout"
    else
      workspace=$(canonical_workspace_path "$workspace")
    fi
    check_safe_workspace_path "$workspace" "$source_path"
    [[ ! -e "$workspace" ]] || fail "workspace already exists: $workspace"
    mkdir -p -- "$(dirname -- "$workspace")"

    if ! git -C "$source_path" worktree add --detach "$workspace" "$baseline_commit" >/dev/null; then
      fail "could not create execution worktree: $workspace"
    fi
    if ! printf '%s\n' "$marker_content" > "$workspace/$marker_name"; then
      git -C "$source_path" worktree remove --force "$workspace" >/dev/null 2>&1 || true
      fail "could not mark execution worktree: $workspace"
    fi
    printf '%s\n' "$workspace"
    ;;
  check)
    workspace=''
    baseline=''
    owned=()
    frozen=()
    while (($#)); do
      case "$1" in
        --workspace)
          (($# > 1)) || fail '--workspace requires a path'
          workspace=$2
          shift 2
          ;;
        --workspace=*)
          workspace=$(printf '%s' "$1" | cut -d= -f2-)
          shift
          ;;
        --baseline)
          (($# > 1)) || fail '--baseline requires a revision'
          baseline=$2
          shift 2
          ;;
        --baseline=*)
          baseline=$(printf '%s' "$1" | cut -d= -f2-)
          shift
          ;;
        --owned)
          (($# > 1)) || fail '--owned requires a path'
          owned+=("$2")
          shift 2
          ;;
        --owned=*)
          owned+=("$(printf '%s' "$1" | cut -d= -f2-)")
          shift
          ;;
        --frozen)
          (($# > 1)) || fail '--frozen requires a path'
          frozen+=("$2")
          shift 2
          ;;
        --frozen=*)
          frozen+=("$(printf '%s' "$1" | cut -d= -f2-)")
          shift
          ;;
        --help|-h)
          show_usage
          exit 0
          ;;
        *)
          fail "unrecognized argument for check: $1"
          ;;
      esac
    done

    [[ -n "$workspace" ]] || fail '--workspace is required'
    [[ -n "$baseline" ]] || fail '--baseline is required'
    ((${#owned[@]} > 0)) || fail 'at least one --owned path is required'
    [[ ! -L "$workspace" ]] || fail "refusing to use a symlink as a workspace: $workspace"
    workspace=$(canonical_existing_path "$workspace")
    check_safe_workspace_path "$workspace"
    read_marker "$workspace"

    scope_args=(--baseline "$baseline" --owned "$marker_name")
    for path in "${owned[@]}"; do
      scope_args+=(--owned "$path")
    done
    for path in "${frozen[@]}"; do
      scope_args+=(--frozen "$path")
    done
    if (
      cd -P -- "$workspace"
      bash "$scope_checker" "${scope_args[@]}"
    ); then
      read_marker "$workspace"
    else
      exit $?
    fi
    ;;
  cleanup)
    source=''
    workspace=''
    retain=0
    while (($#)); do
      case "$1" in
        --source-repo)
          (($# > 1)) || fail '--source-repo requires a path'
          source=$2
          shift 2
          ;;
        --source-repo=*)
          source=$(printf '%s' "$1" | cut -d= -f2-)
          shift
          ;;
        --workspace)
          (($# > 1)) || fail '--workspace requires a path'
          workspace=$2
          shift 2
          ;;
        --workspace=*)
          workspace=$(printf '%s' "$1" | cut -d= -f2-)
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
          fail "unrecognized argument for cleanup: $1"
          ;;
      esac
    done

    [[ "${OFFLOAD_WORKER_CONTEXT:-}" != 1 ]] || fail 'worker context cannot remove an execution workspace' 126
    [[ -n "$source" ]] || fail '--source-repo is required'
    [[ -n "$workspace" ]] || fail '--workspace is required'
    [[ ! -L "$workspace" ]] || fail "refusing to clean a symlink: $workspace"
    source_path=$(require_git_repo "$source")
    workspace=$(canonical_existing_path "$workspace")
    check_safe_workspace_path "$workspace" "$source_path"
    read_marker "$workspace"
    require_registered_worktree "$source_path" "$workspace"

    if ((retain)); then
      printf 'Retained execution workspace: %s\n' "$workspace"
      exit 0
    fi

    git -C "$source_path" worktree remove --force "$workspace" >/dev/null || fail "could not remove execution worktree: $workspace"
    if [[ -e "$workspace" ]]; then
      rm -rf -- "$workspace"
    fi
    git -C "$source_path" worktree prune >/dev/null 2>&1 || true
    remove_empty_generated_parent "$workspace"
    printf 'Removed execution workspace: %s\n' "$workspace"
    ;;
  --help|-h|'')
    show_usage
    exit 1
    ;;
  *)
    fail "unrecognized command: $command (expected create, check, or cleanup)"
    ;;
esac
