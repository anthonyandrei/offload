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
  if [ "$scenario" = timed-out-models ]; then sleep 16; exit 124; fi
  if [ "$scenario" = models-exit-124 ]; then exit 124; fi
  if [ "$scenario" = models-exit-137 ]; then exit 137; fi
  jq -r '.model_list[]' "$fixture"
  exit 0
fi

if [ "$#" -ge 4 ] && [ "$1" = -p ] && [ "$2" = /usage ] && \
   [ "$3" = --output-format ] && [ "$4" = json ]; then
  case "$scenario" in
    unsupported|unsupported-usage|redaction-unsupported|redaction-unsupported-usage)
      printf '%s\n' 'unknown option: /usage' >&2
      exit 2
      ;;
    malformed|malformed-usage)
      printf '%s\n' '{malformed usage response'
      exit 0
      ;;
    timed-out|timed-out-usage)
      sleep 16
      exit 124
      ;;
    usage-exit-124)
      exit 124
      ;;
    usage-exit-137)
      exit 137
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
