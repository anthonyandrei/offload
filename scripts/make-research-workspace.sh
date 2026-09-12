#!/usr/bin/env bash
set -euo pipefail

marker_name='.offload-research-workspace'
marker_content='offload-research-workspace-v2'
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

fail() {
  local code=1
  if (($# > 1)); then
    code=$2
  fi
  printf 'Error: %s\n' "$1" >&2
  exit "$code"
}

cleanup_failed_research_creation() {
  local status=$?
  if ((status != 0)) && [[ "${workspace_created:-0}" = 1 ]] && [[ -n "${workspace:-}" ]]; then
    rm -rf -- "$workspace" >/dev/null 2>&1 || true
  fi
  return "$status"
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

check_safe_workspace_path() {
  local workspace=$1
  local source=${2:-}
  [[ "$workspace" != '/' ]] || fail "refusing to use a filesystem root: $workspace"
  local cwd
  cwd=$(CDPATH= cd -P -- "$PWD" && pwd -P)
  [[ "$workspace" != "$cwd" ]] || fail "refusing to use the current directory: $workspace"
  if [[ -n "${HOME:-}" && -d "$HOME" ]]; then
    local home
    home=$(CDPATH= cd -P -- "$HOME" && pwd -P)
    [[ "$workspace" != "$home" ]] || fail "refusing to use a user home directory: $workspace"
  fi
  if [[ -n "$source" ]] && path_is_within "$workspace" "$source"; then
    fail "research workspace must be outside the source directory: $workspace"
  fi
}

normalize_relative_path() {
  local raw=$1
  [[ -n "$raw" ]] || fail 'research path cannot be empty'
  case "$raw" in
    /*|\\*) fail "research path must be relative: $raw" ;;
  esac
  raw=$(printf '%s' "$raw" | tr '\\' '/')
  local part normalized=''
  local -a parts
  IFS='/' read -r -a parts <<< "$raw"
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" = '.' ]] && continue
    [[ "$part" != '..' ]] || fail "research path escapes the source directory: $1"
    [[ "$part" != '.git' ]] || fail 'research snapshots cannot include Git metadata'
    if [[ -z "$normalized" ]]; then
      normalized=$part
    else
      normalized="$normalized/$part"
    fi
  done
  [[ -n "$normalized" ]] || fail "research path resolves to the source directory: $1"
  printf '%s\n' "$normalized"
}

assert_no_links() {
  local path=$1
  [[ ! -L "$path" ]] || fail "research snapshots cannot copy links or reparse points: $path"
  if [[ -d "$path" ]]; then
    local link
    link=$(find -P "$path" -type l -print -quit)
    [[ -z "$link" ]] || fail "research snapshots cannot copy links or reparse points: $link"
  fi
}

assert_path_components_are_real() {
  local source=$1
  local relative=$2
  local candidate=$source
  local part
  local -a parts
  IFS='/' read -r -a parts <<< "$relative"
  for part in "${parts[@]}"; do
    candidate="$candidate/$part"
    [[ ! -L "$candidate" ]] || fail "research snapshots cannot traverse links or reparse points: $candidate"
  done
}

show_usage() {
  cat >&2 <<'USAGE'
Usage:
  make-research-workspace.sh --source-repo <path> --path <relative-path> [--path <relative-path> ...] [--workspace <path>]

The helper copies only the declared source paths into a marked disposable
snapshot under the workspace's repo directory.
USAGE
}

[[ "${OFFLOAD_WORKER_CONTEXT:-}" != 1 ]] || fail 'worker context cannot create a research snapshot' 126

source=''
workspace=''
workspace_created=0
paths=()
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
    --path)
      (($# > 1)) || fail '--path requires a relative path'
      paths+=("$2")
      shift 2
      ;;
    --path=*)
      paths+=("$(printf '%s' "$1" | cut -d= -f2-)")
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
      fail "unrecognized argument: $1"
      ;;
  esac
done

[[ -n "$source" ]] || fail '--source-repo is required'
((${#paths[@]} > 0)) || fail 'at least one --path is required'
source_path=$(canonical_existing_path "$source")
git -C "$source_path" rev-parse --show-toplevel >/dev/null 2>&1 || fail "source directory is not a Git repository: $source_path"
source_path=$(canonical_existing_path "$(git -C "$source_path" rev-parse --show-toplevel)")

relative_paths=()
for raw_path in "${paths[@]}"; do
  relative_path=$(normalize_relative_path "$raw_path")
  assert_path_components_are_real "$source_path" "$relative_path"
  source_item="$source_path/$relative_path"
  [[ -e "$source_item" ]] || fail "declared research path does not exist: $raw_path"
  assert_no_links "$source_item"
  relative_paths+=("$relative_path")
done

if [[ -z "$workspace" ]]; then
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/offload-research-XXXXXX") || fail 'could not create a research workspace'
  workspace_created=1
  trap cleanup_failed_research_creation EXIT
  check_safe_workspace_path "$workspace" "$source_path"
else
  workspace=$(canonical_workspace_path "$workspace")
  check_safe_workspace_path "$workspace" "$source_path"
  [[ ! -e "$workspace" ]] || fail "workspace already exists: $workspace"
  mkdir -p -- "$workspace"
  workspace_created=1
  trap cleanup_failed_research_creation EXIT
fi
printf '%s\n' "$marker_content" > "$workspace/$marker_name"

repo_root="$workspace/repo"
for relative_path in "${relative_paths[@]}"; do
  source_item="$source_path/$relative_path"
  destination="$repo_root/$relative_path"
  if [[ -d "$source_item" ]]; then
    mkdir -p -- "$destination"
    cp -R -- "$source_item"/. "$destination"/
  else
    mkdir -p -- "$(dirname -- "$destination")"
    cp -- "$source_item" "$destination"
  fi
done

trap - EXIT
printf '%s\n' "$workspace"
