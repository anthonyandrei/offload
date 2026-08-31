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

if [[ ! -d "$workspace" ]]; then
  printf 'Error: workspace directory does not exist: %s\n' "$workspace" >&2
  exit 1
fi

canonical_ws=$(cd "$workspace" && pwd)
if [[ "$canonical_ws" == "/" || "$canonical_ws" == "$HOME" || "$canonical_ws" == "$(pwd)" ]]; then
  printf 'Error: unsafe workspace path: %s\n' "$canonical_ws" >&2
  exit 1
fi

if [[ "$status" == "success" ]]; then
  shopt -s nullglob dotglob
  for entry in "$workspace"/*; do
    base=$(basename "$entry")
    if [[ "$base" != "final.md" && "$base" != "provenance.json" ]]; then
      rm -rf "$entry"
    fi
  done
  shopt -u nullglob dotglob
fi
