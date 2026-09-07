#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || exit 64
counter=$1
count=0
if [[ -f "$counter" ]]; then
  count=$(<"$counter")
fi
printf '%s\n' "$((count + 1))" > "$counter"
exit 17
