#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 1 ]] || exit 64
counter=$1
mode=${2:-launch}
lifecycle_workspace=${3:-}
count=0
if [[ -f "$counter" ]]; then
  count=$(<"$counter")
fi
printf '%s\n' "$((count + 1))" > "$counter"

if [[ -n "$lifecycle_workspace" ]]; then
  printf 'deliverable for %s\n' "$mode" > "$lifecycle_workspace/deliverables.txt"
  printf 'diff for %s\n' "$mode" > "$lifecycle_workspace/diffs.txt"
  printf 'evidence for %s\n' "$mode" > "$lifecycle_workspace/evidence.txt"
  printf 'transient run facts for %s\n' "$mode" > "$lifecycle_workspace/transient-run-facts.txt"
fi

case "$mode" in
  success|local-finish)
    exit 0
    ;;
  timeout)
    exit 124
    ;;
  quality-failure)
    exit 20
    ;;
  escalation-failure)
    exit 30
    ;;
  quality-escalate)
    if [[ $count -ge 2 ]]; then
      exit 30
    fi
    exit 20
    ;;
  launch|launch-failure|*)
    exit 17
    ;;
esac
