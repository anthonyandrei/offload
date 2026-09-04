#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-2}"; }

operation=''
request_path=''
output_path=''
error_path=''
worker_args=()
after_delimiter=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --operation|--request|--output|--error)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in
        --operation) operation="$2" ;;
        --request) request_path="$2" ;;
        --output) output_path="$2" ;;
        --error) error_path="$2" ;;
      esac
      shift 2
      ;;
    --)
      after_delimiter=true
      shift
      worker_args=("$@")
      break
      ;;
    *) fail "unknown adapter option: $1" ;;
  esac
done

[ "$operation" = catalog ] || [ "$operation" = launch ] || fail 'operation must be catalog or launch'
[ -n "$request_path" ] && [ -f "$request_path" ] || fail 'request file is required'

agy_bin="${AGY_BIN:-agy}"
if [ "$operation" = catalog ]; then
  if [ -n "${OFFLOAD_ADAPTER_CATALOG:-}" ]; then
    [ -f "$OFFLOAD_ADAPTER_CATALOG" ] || fail "catalog file not found: $OFFLOAD_ADAPTER_CATALOG" 127
    jq empty "$OFFLOAD_ADAPTER_CATALOG" >/dev/null 2>&1 || fail 'catalog file is not valid JSON' 127
    cat "$OFFLOAD_ADAPTER_CATALOG"
    exit 0
  fi
  models_tmp=$(mktemp)
  models_err=$(mktemp)
  trap 'rm -f "$models_tmp" "$models_err"' EXIT
  set +e
  "$agy_bin" models >"$models_tmp" 2>"$models_err"
  models_code=$?
  set -e
  if [ "$models_code" -ne 0 ]; then
    printf 'ERROR: AGY catalog discovery failed with exit code %s: %s\n' "$models_code" "$(tr '\n' ' ' <"$models_err")" >&2
    exit 127
  fi
  catalog_revision=''
  if command -v sha256sum >/dev/null 2>&1; then
    catalog_revision=$(sha256sum "$models_tmp" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    catalog_revision=$(shasum -a 256 "$models_tmp" | awk '{print $1}')
  else
    printf 'ERROR: no SHA-256 implementation is available for catalog revision\n' >&2
    exit 127
  fi
  jq -Rn --arg revision "$catalog_revision" '
    def family:
      if test("^gemini-[^-]+-flash-") then "flash"
      elif test("^gemini-[^-]+-pro-") then "pro"
      elif test("^claude-[^-]+-opus") then "opus"
      elif test("^claude-[^-]+-sonnet") then "sonnet"
      elif test("^claude-[^-]+-haiku") then "haiku"
      elif test("^gpt-oss-") then "oss"
      else "unknown" end;
    def score($family; $preference):
      if $preference == "fast" then ({flash:1,haiku:2,oss:2,sonnet:3,pro:4,opus:5,unknown:100}[$family] // 100)
      elif $preference == "balanced" then ({sonnet:1,flash:2,oss:3,pro:3,haiku:4,opus:5,unknown:100}[$family] // 100)
      else ({opus:1,pro:2,sonnet:3,oss:4,flash:5,haiku:6,unknown:100}[$family] // 100) end;
    {
      protocol_version: 1,
      adapter: "agy",
      adapter_revision: "agy-1",
      vendor: "agy",
      catalog_revision: $revision,
      models: [
        inputs
        | capture("^\\s*(?<id>\\S+)\\s+(?<label>.+?)\\s*$")
        | select(.id | test("-(low|medium|high)$"))
        | (.id | capture("-(?<effort>low|medium|high)$")) as $effort
        | (.id | family) as $family
        | {
            id: .id,
            family_hint: $family,
            available: true,
            quota_available: true,
            supported_efforts: [$effort.effort],
            capabilities: [],
            scores: {
              fast: score($family; "fast"),
              balanced: score($family; "balanced"),
              deep: score($family; "deep")
            }
          }
      ]
    }
  ' "$models_tmp"
  exit 0
fi

$after_delimiter && [ "${#worker_args[@]}" -gt 0 ] || fail 'worker arguments are required after --'
[ -n "$output_path" ] && [ -n "$error_path" ] || fail 'launch requires output and error paths'
model_id=$(jq -er '.model_id // .model // empty' "$request_path") || fail 'selection is missing model_id'

# AGY accepts the exact model ID here. The launcher never needs to know this syntax.
set +e
"$agy_bin" --model "$model_id" "${worker_args[@]}" >"$output_path" 2>"$error_path"
code=$?
set -e
exit "$code"
