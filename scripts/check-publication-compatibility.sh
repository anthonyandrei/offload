#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'usage: check-publication-compatibility.sh --skill-root DIR --catalog FILE' >&2
  exit 2
}

fail() {
  printf 'compatibility error: %s\n' "$1" >&2
  exit 1
}

skill_root=''
catalog=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skill-root) [ "$#" -ge 2 ] || usage; skill_root=$2; shift 2 ;;
    --catalog) [ "$#" -ge 2 ] || usage; catalog=$2; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$skill_root" ] || usage
[ -n "$catalog" ] || usage
[ -d "$skill_root" ] || fail "skill root does not exist: $skill_root"
[ -f "$catalog" ] || fail "adapter catalog does not exist: $catalog"
[ -f "$skill_root/publication.json" ] || fail 'published skill is missing publication.json'
[ -f "$skill_root/SKILL.md" ] || fail 'published skill is missing SKILL.md'

command -v jq >/dev/null 2>&1 || fail 'jq is required'
jq empty "$skill_root/publication.json" >/dev/null 2>&1 || fail 'invalid publication JSON'
jq empty "$catalog" >/dev/null 2>&1 || fail 'invalid adapter catalog JSON'

manifest="$skill_root/publication.json"
[ "$(jq -r '.schema_version // empty' "$manifest")" = '1' ] || fail 'publication.json schema_version must be 1'
[ "$(jq -r '.publication_contract_version // empty' "$manifest")" = '1' ] || fail 'publication contract version 1 is required'
[ "$(jq -r '.contract // empty' "$manifest")" = 'vendor-neutral' ] || fail 'published skills must use the vendor-neutral contract'
[ "$(jq -r '.schema_version // empty' "$catalog")" = '1' ] || fail 'adapter catalog schema_version must be 1'
[ "$(jq -r '.adapter_contract_version // empty' "$catalog")" = '1' ] || fail 'adapter contract version 1 is required'

version_at_least() {
  local available=$1 minimum=$2
  local available_major available_minor available_patch
  local minimum_major minimum_minor minimum_patch
  IFS=. read -r available_major available_minor available_patch <<< "$available"
  IFS=. read -r minimum_major minimum_minor minimum_patch <<< "$minimum"
  [[ "$available_major" =~ ^[0-9]+$ && "$available_minor" =~ ^[0-9]+$ && "$available_patch" =~ ^[0-9]+$ ]] || return 1
  [[ "$minimum_major" =~ ^[0-9]+$ && "$minimum_minor" =~ ^[0-9]+$ && "$minimum_patch" =~ ^[0-9]+$ ]] || return 1
  if [ "$available_major" -ne "$minimum_major" ]; then
    [ "$available_major" -gt "$minimum_major" ]
  elif [ "$available_minor" -ne "$minimum_minor" ]; then
    [ "$available_minor" -gt "$minimum_minor" ]
  else
    [ "$available_patch" -ge "$minimum_patch" ]
  fi
}

while IFS= read -r import; do
  name=$(jq -r '.name // empty' <<<"$import")
  minimum=$(jq -r '.min_version // empty' <<<"$import")
  [ -n "$name" ] || fail 'publication import is missing name'
  [ -n "$minimum" ] || fail "publication import '$name' is missing min_version"
  count=$(jq --arg name "$name" '[.adapters[] | select(.name == $name)] | length' "$catalog")
  [ "$count" = '1' ] || fail "required adapter '$name' is unavailable"
  available=$(jq -r --arg name "$name" '.adapters[] | select(.name == $name) | .version' "$catalog")
  version_at_least "$available" "$minimum" || fail "adapter '$name' version '$available' does not satisfy minimum '$minimum'"
done < <(jq -c '.imports // [] | .[]' "$manifest")

while IFS= read -r import; do
  name=$(jq -r '.name // empty' <<<"$import")
  minimum=$(jq -r '.min_version // empty' <<<"$import")
  [ -n "$name" ] || fail 'optional adapter is missing name'
  [ -n "$minimum" ] || fail "optional adapter '$name' is missing min_version"
  count=$(jq --arg name "$name" '[.adapters[] | select(.name == $name)] | length' "$catalog")
  if [ "$count" = '0' ]; then
    printf "warning: optional adapter '%s' is unavailable\n" "$name"
    continue
  fi
  [ "$count" = '1' ] || fail "adapter catalog repeats '$name'"
  available=$(jq -r --arg name "$name" '.adapters[] | select(.name == $name) | .version' "$catalog")
  version_at_least "$available" "$minimum" || fail "optional adapter '$name' version '$available' does not satisfy minimum '$minimum'"
done < <(jq -c '.optional_adapters // [] | .[]' "$manifest")

while IFS= read -r requirement; do
  adapter=$(jq -r '.adapter // empty' <<<"$requirement")
  capability=$(jq -r '.name // empty' <<<"$requirement")
  [ -n "$adapter" ] || fail 'capability requirement is missing adapter'
  [ -n "$capability" ] || fail 'capability requirement is missing name'
  adapter_count=$(jq --arg adapter "$adapter" '[.adapters[] | select(.name == $adapter)] | length' "$catalog")
  [ "$adapter_count" = '1' ] || fail "capability '$capability' requires unavailable adapter '$adapter'"
  jq -e --arg adapter "$adapter" --arg capability "$capability" \
    '.adapters[] | select(.name == $adapter) | (.capabilities // []) | index($capability) != null' \
    "$catalog" >/dev/null || fail "adapter '$adapter' does not provide capability '$capability'"
done < <(jq -c '.required_capabilities // [] | .[]' "$manifest")

[ "$(jq '(.vendor_features // []) | length' "$manifest")" = '0' ] || \
  fail 'vendor-specific feature declarations are not allowed in a published skill'

vendor_matches=$(mktemp "${TMPDIR:-/tmp}/offload-publication.XXXXXX")
trap 'rm -f "$vendor_matches"' EXIT
vendor_pattern='(^|[^[:alnum:]_-])(AGY|Gemini|Antigravity|Codex|Claude)($|[^[:alnum:]_-])'
if find "$skill_root" -type f -name '*.md' -exec grep -HniE "$vendor_pattern" {} + >"$vendor_matches"; then
  first_match=$(head -n 1 "$vendor_matches")
  fail "vendor-specific reference in published skill: $first_match"
fi

printf '%s\n' 'publication compatibility: pass'
