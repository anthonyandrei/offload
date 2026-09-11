#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 1 ]] || exit 64
counter=$1
mode=${2:-launch}
count=0
if [[ -f "$counter" ]]; then
  count=$(<"$counter")
fi
printf '%s\n' "$((count + 1))" > "$counter"

case "$mode" in
  quality-failure)
    exit 20
    ;;
  quality-escalate)
    if [[ $count -ge 2 ]]; then
      exit 30
    fi
    exit 20
    ;;
  *)
    exit 17
    ;;
esac
