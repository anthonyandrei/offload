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

if [[ -n "$source_repo" ]]; then
  if [[ ! -d "$source_repo" ]]; then
    printf 'Error: source repository does not exist: %s\n' "$source_repo" >&2
    rm -rf "$workspace"
    exit 1
  fi

  source_repo=$(cd "$source_repo" && pwd -P)

  for declared_path in "${paths[@]}"; do
    if [[ "$declared_path" == /* ]]; then
      printf 'Error: declared path must be relative to the source repository: %s\n' "$declared_path" >&2
      rm -rf "$workspace"
      exit 1
    fi

    rel_path="${declared_path#./}"
    IFS='/' read -r -a path_parts <<< "$rel_path"
    for path_part in "${path_parts[@]}"; do
      if [[ "$path_part" == ".." ]]; then
        printf 'Error: declared path escapes the source repository: %s\n' "$declared_path" >&2
        rm -rf "$workspace"
        exit 1
      fi
    done

    src="$source_repo/$rel_path"
    dest="$workspace/repo/$rel_path"

    if [[ -e "$src" ]]; then
      if [[ -L "$src" ]] || find -P "$src" -type l -print -quit | grep -q .; then
        printf 'Error: declared path contains a symlink and cannot be snapshotted: %s\n' "$declared_path" >&2
        rm -rf "$workspace"
        exit 1
      fi
      mkdir -p "$(dirname "$dest")"
      if [[ -d "$src" ]]; then
        mkdir -p "$dest"
        cp -R "$src/." "$dest/"
      else
        cp "$src" "$dest"
      fi
    else
      printf 'Warning: declared path does not exist: %s\n' "$src" >&2
    fi
  done
fi

printf '%s\n' "$workspace"
