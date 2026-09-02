#!/usr/bin/env bash
set -euo pipefail

source_repo=""
paths=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-repo)
      source_repo="$2"
      shift 2
      ;;
    --path)
      paths+=("$2")
      shift 2
      ;;
    -h|--help)
      printf 'Usage: %s [--source-repo <path>] [--path <declared-path> ...]\n' "$0" >&2
      exit 0
      ;;
    *)
      printf 'Error: unrecognized argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

workspace=$(mktemp -d "${TMPDIR:-/tmp}/offload-research.XXXXXX")
workspace=$(cd "$workspace" && pwd -P)

success=false
cleanup() {
  if [[ "$success" != "true" && -n "${workspace:-}" && -d "${workspace:-}" ]]; then
    rm -rf "$workspace"
  fi
}
trap cleanup EXIT

printf 'offload-research-workspace-v1\n' > "$workspace/.offload-research-workspace"

if [[ -n "$source_repo" ]]; then
  if [[ ! -d "$source_repo" ]]; then
    printf 'Error: source repository does not exist: %s\n' "$source_repo" >&2
    exit 1
  fi

  source_repo=$(cd "$source_repo" && pwd -P)

  for declared_path in "${paths[@]}"; do
    # Reject absolute or rooted paths
    case "$declared_path" in
      /* | \\* | [a-zA-Z]:* | ~* )
        printf 'Error: declared path must be relative to the source repository: %s\n' "$declared_path" >&2
        exit 1
        ;;
    esac

    # Reject paths containing parent traversal components
    case "$declared_path" in
      .. | ../* | ..\\* | */.. | *\\.. | */../* | */..\\* | *\\../* | *\\..\\*)
        printf 'Error: declared path escapes the source repository: %s\n' "$declared_path" >&2
        exit 1
        ;;
    esac

    rel_path="${declared_path#./}"
    IFS='/\\' read -r -a path_parts <<< "$rel_path"
    for path_part in "${path_parts[@]}"; do
      if [[ "$path_part" == ".." ]]; then
        printf 'Error: declared path escapes the source repository: %s\n' "$declared_path" >&2
        exit 1
      fi
    done

    # Reject if any directory component in the repository path is a symlink
    current_check="$source_repo"
    for path_part in "${path_parts[@]}"; do
      [[ -z "$path_part" || "$path_part" == "." ]] && continue
      current_check="$current_check/$path_part"
      if [[ -L "$current_check" || -h "$current_check" ]]; then
        printf 'Error: declared path contains a symlink and cannot be snapshotted: %s\n' "$declared_path" >&2
        exit 1
      fi
    done

    src="$source_repo/$rel_path"
    dest="$workspace/repo/$rel_path"

    if [[ -e "$src" ]]; then
      if [[ -L "$src" || -h "$src" ]]; then
        printf 'Error: declared path contains a symlink and cannot be snapshotted: %s\n' "$declared_path" >&2
        exit 1
      fi
      if [[ -d "$src" ]]; then
        if [ -n "$(find -P "$src" -type l -print 2>/dev/null | head -n 1)" ]; then
          printf 'Error: declared directory contains a symlink and cannot be snapshotted: %s\n' "$declared_path" >&2
          exit 1
        fi
        mkdir -p "$dest"
        cp -R "$src/." "$dest/"
      else
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
      fi
    else
      if [[ -L "$src" || -h "$src" ]]; then
        printf 'Error: declared path contains a symlink and cannot be snapshotted: %s\n' "$declared_path" >&2
        exit 1
      fi
      printf 'Warning: declared path does not exist: %s\n' "$src" >&2
    fi
  done
fi

success=true
printf '%s\n' "$workspace"
