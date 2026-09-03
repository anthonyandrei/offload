#!/usr/bin/env bash
# scripts/check-citation-audit.sh
# Platform-agnostic citation audit coverage and verdict consistency verifier for Bash 3.2+.
# Verifies that every required (claim_id, citation_url) pair in the claim ledger
# has exact coverage and consistent verdicts in citation_audits before accepting synthesis.

set -euo pipefail

show_usage() {
  cat << 'EOF' >&2
Usage: check-citation-audit.sh --ledger <FILE|JSON> --auditor <FILE|JSON> [OPTIONS]

Options:
  --ledger, --claim-ledger <FILE|JSON>     Path to synthesizer JSON or raw claim_ledger JSON
  --auditor, --auditor-output <FILE|JSON>  Path to auditor JSON or raw auditor output JSON
  --require-citations                      Require at least one auditable citation pair (default)
  --allow-empty                            Allow zero auditable citation pairs if assignment permits
  --json                                   Output verification result as JSON to stdout
  -h, --help                               Show this help message

Exit codes:
  0 - Audit verified and passed automated acceptance (all pairs supported, final_status pass)
  1 - Valid revision required (complete coverage, final_status revise)
  2 - Invalid audit (missing coverage, duplicates, unknown pairs, contradictory verdicts, etc.)
EOF
}

ledger_arg=""
auditor_arg=""
require_citations=true
json_output=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ledger|--claim-ledger)
      [ $# -ge 2 ] || { echo "Error: $1 requires an argument" >&2; exit 2; }
      ledger_arg="$2"
      shift 2
      ;;
    --ledger=*|--claim-ledger=*)
      ledger_arg="${1#*=}"
      shift 1
      ;;
    --auditor|--auditor-output)
      [ $# -ge 2 ] || { echo "Error: $1 requires an argument" >&2; exit 2; }
      auditor_arg="$2"
      shift 2
      ;;
    --auditor=*|--auditor-output=*)
      auditor_arg="${1#*=}"
      shift 1
      ;;
    --require-citations)
      require_citations=true
      shift 1
      ;;
    --allow-empty)
      require_citations=false
      shift 1
      ;;
    --json)
      json_output=true
      shift 1
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      echo "Error: unrecognized option: $1" >&2
      show_usage
      exit 2
      ;;
  esac
done

if [ -z "$ledger_arg" ]; then
  echo "Error: missing required option --ledger" >&2
  show_usage
  exit 2
fi

if [ -z "$auditor_arg" ]; then
  echo "Error: missing required option --auditor" >&2
  show_usage
  exit 2
fi

# Load ledger content
ledger_json=""
if [ -f "$ledger_arg" ]; then
  ledger_json="$(cat "$ledger_arg")"
else
  ledger_json="$ledger_arg"
fi

# Load auditor content
auditor_json=""
if [ -f "$auditor_arg" ]; then
  auditor_json="$(cat "$auditor_arg")"
else
  auditor_json="$auditor_arg"
fi

# Verify both inputs are valid JSON
if ! echo "$ledger_json" | jq empty >/dev/null 2>&1; then
  echo "Error: ledger input is not valid JSON" >&2
  exit 2
fi

if ! echo "$auditor_json" | jq empty >/dev/null 2>&1; then
  echo "Error: auditor input is not valid JSON" >&2
  exit 2
fi

# Run validation using jq
result_json=$(jq -n \
  --argjson ledger "$ledger_json" \
  --argjson auditor "$auditor_json" \
  --argjson require_citations "$require_citations" '
  # 1. Normalize claim_ledger
  (if ($ledger | type) == "array" then
     $ledger
   elif ($ledger | type) == "object" and ($ledger.structured_output.claim_ledger | type) == "array" then
     $ledger.structured_output.claim_ledger
   elif ($ledger | type) == "object" and ($ledger.claim_ledger | type) == "array" then
     $ledger.claim_ledger
   else
     null
   end) as $claim_ledger
  |
  # 2. Normalize auditor output
  (if ($auditor | type) == "object" and ($auditor.structured_output.citation_audits | type) == "array" then
     $auditor.structured_output
   elif ($auditor | type) == "object" and ($auditor.citation_audits | type) == "array" then
     $auditor
   else
     null
   end) as $aud_out
  |
  if $claim_ledger == null then
    { valid: false, status: "invalid", exit_code: 2, required_pairs_count: 0, audited_pairs_count: 0, final_status: "invalid", errors: ["Invalid claim ledger: input must be an array or an object containing a \"claim_ledger\" array"] }
  elif $aud_out == null then
    { valid: false, status: "invalid", exit_code: 2, required_pairs_count: 0, audited_pairs_count: 0, final_status: "invalid", errors: ["Invalid auditor output: input must be an object containing a \"citation_audits\" array"] }
  else
    # Extract required pairs
    ([ $claim_ledger[]
       | .claim_id as $cid
       | select($cid != null and ($cid | tostring | length > 0))
       | (.citations // [])[]
       | select(. != null and (tostring | length > 0))
       | { claim_id: ($cid | tostring), citation_url: (. | tostring) }
     ] | unique) as $required_pairs
    |
    ($aud_out.citation_audits // []) as $audits
    |
    ($aud_out.final_status // "") as $final_status
    |
    ($aud_out.claims_to_remove // []) as $to_remove
    |
    ($aud_out.claims_to_narrow // []) as $to_narrow
    |
    ($aud_out.claims_unresolved // []) as $unresolved
    |
    # Map audited pairs
    [ $audits[] | { claim_id: (.claim_id // "" | tostring), citation_url: (.citation_url // "" | tostring) } ] as $audited_pairs
    |
    # Check duplicate pairs in citation_audits
    ($audited_pairs | group_by(.) | map(select(length > 1) | .[0])) as $duplicate_pairs
    |
    # Check unknown pairs in citation_audits
    (($audited_pairs | unique) - $required_pairs) as $unknown_pairs
    |
    # Check missing pairs
    ($required_pairs - ($audited_pairs | unique)) as $missing_pairs
    |
    (
      []
      # Error: zero auditable pairs when citations are required
      | if ($required_pairs | length == 0) and $require_citations then
          . + ["Ledger contains no auditable claim/citation pairs, but citations are required by the research assignment"]
        else . end
      # Errors: duplicates
      | . + [ $duplicate_pairs[] | "Duplicate audit entry found for claim_id \"\(.claim_id)\" and citation_url \"\(.citation_url)\"" ]
      # Errors: unknown pairs
      | . + [ $unknown_pairs[] | "Unknown audit entry for claim_id \"\(.claim_id)\" and citation_url \"\(.citation_url)\" not present in claim ledger" ]
      # Errors: missing pairs
      | . + [ $missing_pairs[] | "Missing audit coverage for required pair: claim_id \"\(.claim_id)\", citation_url \"\(.citation_url)\"" ]
      # Error: final_status validity
      | if (["pass", "revise", "incomplete"] | index($final_status)) == null then
          . + ["Invalid or missing final_status \"\($final_status)\"; must be pass, revise, or incomplete"]
        else . end
      # Verdict consistency for pass
      | if $final_status == "pass" then
          . + [ $audits[] | select(.resolves != true) | "Contradictory audit: final_status is \"pass\" but pair (claim_id \"\(.claim_id)\", citation_url \"\(.citation_url)\") has resolves=false" ]
          | . + [ $audits[] | select(.support_verdict != "supports") | "Contradictory audit: final_status is \"pass\" but pair (claim_id \"\(.claim_id)\", citation_url \"\(.citation_url)\") has non-supporting verdict \"\(.support_verdict)\"" ]
          | if ($to_remove | length > 0) then . + ["Contradictory audit: final_status is \"pass\" but claims_to_remove is not empty"] else . end
          | if ($to_narrow | length > 0) then . + ["Contradictory audit: final_status is \"pass\" but claims_to_narrow is not empty"] else . end
          | if ($unresolved | length > 0) then . + ["Contradictory audit: final_status is \"pass\" but claims_unresolved is not empty"] else . end
        else . end
      # Verdict consistency for revise
      | if $final_status == "revise" then
          if ($audits | all(.resolves == true and .support_verdict == "supports")) and ($to_remove | length == 0) and ($to_narrow | length == 0) and ($unresolved | length == 0) then
            . + ["Contradictory audit: final_status is \"revise\" but all citations are supported and no claims are marked to remove, narrow, or unresolved"]
          else . end
        else . end
      # Verdict consistency for incomplete
      | if $final_status == "incomplete" then
          . + ["Audit final_status is incomplete"]
        else . end
    ) as $errors
    |
    if ($errors | length > 0) then
      {
        valid: false,
        status: "invalid",
        exit_code: 2,
        required_pairs_count: ($required_pairs | length),
        audited_pairs_count: ($audited_pairs | length),
        final_status: $final_status,
        errors: $errors
      }
    elif $final_status == "revise" then
      {
        valid: true,
        status: "revise",
        exit_code: 1,
        required_pairs_count: ($required_pairs | length),
        audited_pairs_count: ($audited_pairs | length),
        final_status: $final_status,
        errors: []
      }
    else
      {
        valid: true,
        status: "pass",
        exit_code: 0,
        required_pairs_count: ($required_pairs | length),
        audited_pairs_count: ($audited_pairs | length),
        final_status: $final_status,
        errors: []
      }
    end
  end
')

exit_code=$(echo "$result_json" | jq -r '.exit_code')
status=$(echo "$result_json" | jq -r '.status')

if [ "$json_output" = true ]; then
  echo "$result_json"
else
  if [ "$exit_code" -eq 0 ]; then
    req_count=$(echo "$result_json" | jq -r '.required_pairs_count')
    echo "ok: citation audit verified ($req_count required pair(s) covered with supported verdicts)"
  elif [ "$exit_code" -eq 1 ]; then
    echo "revise: citation audit verified; revision required by auditor" >&2
  else
    echo "Error: citation audit verification failed:" >&2
    echo "$result_json" | jq -r '.errors[]' | while IFS= read -r err; do
      echo "  - $err" >&2
    done
  fi
fi

exit "$exit_code"
