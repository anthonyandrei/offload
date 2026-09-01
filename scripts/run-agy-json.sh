#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --output FILE --error FILE -- agy-arguments...\n' "$0" >&2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

output_path=''
error_path=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || { usage; fail '--output requires a path'; }
      output_path=$2
      shift 2
      ;;
    --error)
      [ "$#" -ge 2 ] || { usage; fail '--error requires a path'; }
      error_path=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      fail "unknown launcher option: $1"
      ;;
  esac
done

[ -n "$output_path" ] || { usage; fail '--output is required'; }
[ -n "$error_path" ] || { usage; fail '--error is required'; }
[ "$#" -gt 0 ] || { usage; fail 'agy arguments are required after --'; }

for argument in "$@"; do
  case "$argument" in
    --output|--output=*)
      fail 'do not pass --output to agy; use the launcher --output path instead'
      ;;
  esac
done

if [ -n "${AGY_BIN:-}" ]; then
  agy_bin=$AGY_BIN
elif command -v agy >/dev/null 2>&1; then
  agy_bin=$(command -v agy)
elif [ -x "$HOME/.local/bin/agy" ]; then
  agy_bin="$HOME/.local/bin/agy"
else
  fail 'agy was not found on PATH or at ~/.local/bin/agy'
fi

[ -x "$agy_bin" ] || fail "agy is not executable: $agy_bin"

mkdir -p "$(dirname "$output_path")" "$(dirname "$error_path")"
"$agy_bin" "$@" >"$output_path" 2>"$error_path"
