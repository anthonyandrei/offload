#!/usr/bin/env bash
set -euo pipefail

fixture="${AGY_PREFLIGHT_FIXTURE:?AGY_PREFLIGHT_FIXTURE is required}"
call_log="${AGY_PREFLIGHT_CALL_LOG:?AGY_PREFLIGHT_CALL_LOG is required}"
scenario="${AGY_PREFLIGHT_SCENARIO:-discovery}"

printf '%s\n' "$*" >>"$call_log"

if [[ "$scenario" == redaction* ]]; then
  printf 'token=%s account=private-account billing=private-route\n' \
    "$(jq -r '.redaction_sentinel' "$fixture")" >&2
fi

if [ "$#" -eq 1 ] && [ "$1" = models ]; then
  jq -r '.model_list[]' "$fixture"
  exit 0
fi

if [ "$#" -ge 4 ] && [ "$1" = -p ] && [ "$2" = /usage ] && \
   [ "$3" = --output-format ] && [ "$4" = json ]; then
  case "$scenario" in
    unsupported|redaction-unsupported)
      printf '%s\n' 'unknown option: /usage' >&2
      exit 2
      ;;
    malformed)
      printf '%s\n' '{malformed usage response'
      exit 0
      ;;
    timed-out)
      sleep 2
      exit 124
      ;;
    *)
      printf '%s\n' '{"status":"SUCCESS","groups":[{"id":"gemini","buckets":[{"id":"gemini-fixture","window":"daily","remaining_fraction":0.75,"reset_time":"2099-01-01T00:00:00Z"}]}]}'
      exit 0
      ;;
  esac
fi

if printf '%s\n' "$*" | grep -Eq '(^| )--model( |=)'; then
  printf '%s\n' '{"status":"success","structured_output":{"ok":true}}'
  exit 0
fi

printf '%s\n' 'unexpected fake AGY invocation' >&2
exit 2
