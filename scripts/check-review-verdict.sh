#!/usr/bin/env bash
# scripts/check-review-verdict.sh
# Verify exhaustive reviewer coverage and evidence against one immutable artifact.

set -euo pipefail

show_usage() {
  cat >&2 <<'EOF'
Usage: check-review-verdict.sh --criteria <FILE|JSON> --review <FILE|JSON> --artifact FILE [--json]

The criteria input is an array of objects with stable `criterion_id` values.
The review input is an object containing `criteria`, or an agy envelope whose
`structured_output` contains `criteria`.

Exit codes:
  0 - Every requested criterion has one passing verdict with matching evidence
  1 - Complete review requires direct orchestrator review (fail or hedge)
  2 - Invalid, incomplete, duplicate, unknown, or forged review
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 2
}

criteria_arg=''
review_arg=''
artifact_path=''
json_output=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --criteria)
      [ "$#" -ge 2 ] || fail '--criteria requires a value'
      criteria_arg="$2"
      shift 2
      ;;
    --criteria=*)
      criteria_arg="${1#--criteria=}"
      shift
      ;;
    --review)
      [ "$#" -ge 2 ] || fail '--review requires a value'
      review_arg="$2"
      shift 2
      ;;
    --review=*)
      review_arg="${1#--review=}"
      shift
      ;;
    --artifact)
      [ "$#" -ge 2 ] || fail '--artifact requires a path'
      artifact_path="$2"
      shift 2
      ;;
    --artifact=*)
      artifact_path="${1#--artifact=}"
      shift
      ;;
    --json)
      json_output=true
      shift
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      show_usage
      fail "unrecognized option: $1"
      ;;
  esac
done

[ -n "$criteria_arg" ] || { show_usage; fail 'missing required option --criteria'; }
[ -n "$review_arg" ] || { show_usage; fail 'missing required option --review'; }
[ -n "$artifact_path" ] || { show_usage; fail 'missing required option --artifact'; }
[ -f "$artifact_path" ] || fail "artifact file not found: $artifact_path"

read_json() {
  if [ -f "$1" ]; then
    cat "$1"
  else
    printf '%s' "$1"
  fi
}

criteria_json=$(read_json "$criteria_arg")
review_json=$(read_json "$review_arg")

printf '%s' "$criteria_json" | jq empty >/dev/null 2>&1 || fail 'criteria input is not valid JSON'
printf '%s' "$review_json" | jq empty >/dev/null 2>&1 || fail 'review input is not valid JSON'

result_json=$(jq -n \
  --argjson requested "$criteria_json" \
  --argjson review "$review_json" \
  --rawfile artifact "$artifact_path" '
  def nonempty_string:
    type == "string" and length > 0;
  def normalize_requested:
    if ($requested | type) == "array" then $requested
    elif ($requested | type) == "object" and ($requested.criteria | type) == "array" then $requested.criteria
    else null end;
  def normalize_review:
    if ($review | type) == "array" then $review
    elif ($review | type) == "object" and ($review.structured_output.criteria | type) == "array" then $review.structured_output.criteria
    elif ($review | type) == "object" and ($review.criteria | type) == "array" then $review.criteria
    else null end;
  def criterion_id:
    if (type == "object" and (.criterion_id | nonempty_string)) then .criterion_id else null end;
  def review_id:
    if (type == "object" and (.criterion_id | nonempty_string)) then .criterion_id else null end;

  (normalize_requested) as $requested_items |
  (normalize_review) as $review_items |
  if $requested_items == null then
    {valid:false, status:"invalid", exit_code:2, requested_count:0, returned_count:0, errors:["Criteria input must be an array or an object containing a criteria array"]}
  elif ($requested_items | length) == 0 then
    {valid:false, status:"invalid", exit_code:2, requested_count:0, returned_count:0, errors:["At least one requested criterion is required"]}
  elif $review_items == null then
    {valid:false, status:"invalid", exit_code:2, requested_count:($requested_items|length), returned_count:0, errors:["Review input must contain a criteria array"]}
  else
    ([ $requested_items[] | criterion_id ]) as $requested_ids_or_null |
    ([ $requested_items[] | select((criterion_id) == null) ]) as $malformed_requested |
    ([ $review_items[] | review_id ]) as $returned_ids_or_null |
    ([ $review_items[] | select((review_id) == null or (.verdict | type) != "string" or (.verdict as $verdict | (["pass","fail","hedge"] | index($verdict)) == null) or (.quote | type) != "string") ]) as $malformed_review |
    ($requested_ids_or_null | map(select(. != null))) as $requested_ids |
    ($returned_ids_or_null | map(select(. != null))) as $returned_ids |
    ($requested_ids | group_by(.) | map(select(length > 1) | .[0])) as $duplicate_requested |
    ($returned_ids | group_by(.) | map(select(length > 1) | .[0])) as $duplicate_returned |
    (($returned_ids | unique) - $requested_ids) as $unknown_ids |
    ($requested_ids - ($returned_ids | unique)) as $missing_ids |
    (
      []
      | if ($malformed_requested | length) > 0 then . + ["Criteria contains an item without a non-empty string criterion_id"] else . end
      | if ($duplicate_requested | length) > 0 then . + [ $duplicate_requested[] | "Duplicate requested criterion_id \"\(.)\"" ] else . end
      | if ($malformed_review | length) > 0 then . + ["Review contains an item with an invalid criterion_id, verdict, or quote"] else . end
      | if ($duplicate_returned | length) > 0 then . + [ $duplicate_returned[] | "Duplicate reviewer verdict for criterion_id \"\(.)\"" ] else . end
      | if ($unknown_ids | length) > 0 then . + [ $unknown_ids[] | "Unknown reviewer criterion_id \"\(.)\"" ] else . end
      | if ($missing_ids | length) > 0 then . + [ $missing_ids[] | "Missing reviewer verdict for criterion_id \"\(.)\"" ] else . end
      | if ($malformed_requested|length) == 0 and ($malformed_review|length) == 0 and ($duplicate_requested|length) == 0 and ($duplicate_returned|length) == 0 and ($unknown_ids|length) == 0 and ($missing_ids|length) == 0 then
          . + [ $review_items[] | select(.verdict == "pass") | .quote as $quote | if ($quote | length) == 0 or ($quote | contains("\n")) or ($quote | contains("\r")) then "Passing criterion \"\(.criterion_id)\" must quote one literal artifact line" elif (($artifact | split("\n")) | index($quote)) == null then "Evidence quote for criterion \"\(.criterion_id)\" does not match a literal artifact line" else empty end ]
        else . end
    ) as $errors |
    if ($errors | length) > 0 then
      {valid:false, status:"invalid", exit_code:2, requested_count:($requested_ids|length), returned_count:($returned_ids|length), errors:$errors}
    elif ([ $review_items[] | select(.verdict != "pass") ] | length) > 0 then
      {valid:true, status:"review", exit_code:1, requested_count:($requested_ids|length), returned_count:($returned_ids|length), errors:[]}
    else
      {valid:true, status:"pass", exit_code:0, requested_count:($requested_ids|length), returned_count:($returned_ids|length), errors:[]}
    end
  end
')

exit_code=$(printf '%s' "$result_json" | jq -r '.exit_code')
if $json_output; then
  printf '%s\n' "$result_json"
elif [ "$exit_code" -eq 0 ]; then
  requested_count=$(printf '%s' "$result_json" | jq -r '.requested_count')
  printf 'ok: reviewer verdict verified (%s criterion(s) covered with matching evidence)\n' "$requested_count"
elif [ "$exit_code" -eq 1 ]; then
  printf 'review: complete reviewer coverage requires direct orchestrator review\n' >&2
else
  printf 'Error: reviewer verdict verification failed:\n' >&2
  printf '%s' "$result_json" | jq -r '.errors[]' | while IFS= read -r error; do
    printf '  - %s\n' "$error" >&2
  done
fi

exit "$exit_code"
