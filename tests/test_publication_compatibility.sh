#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECKER="$ROOT_DIR/scripts/check-publication-compatibility.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-publication.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() { printf 'ok - %s\n' "$1"; }

run_checker() {
  set +e
  CHECKER_OUTPUT=$("$CHECKER" --skill-root "$1" --catalog "$2" 2>&1)
  CHECKER_EXIT=$?
  set -e
}

cat > "$TMP_ROOT/catalog.json" <<'JSON'
{
  "schema_version": 1,
  "adapter_contract_version": 1,
  "adapters": [
    {
      "name": "offload",
      "version": "1.2.0",
      "capabilities": ["worker-delegation", "structured-results"],
      "vendor_features": ["agy-launch"]
    }
  ]
}
JSON

make_valid_skill() {
  mkdir -p "$1"
  printf '%s\n' '# grill-with-docs' '' 'Interview and documentation workflow.' > "$1/SKILL.md"
  cat > "$1/publication.json" <<'JSON'
{
  "schema_version": 1,
  "publication_contract_version": 1,
  "skill": "grill-with-docs",
  "contract": "vendor-neutral",
  "imports": [],
  "optional_adapters": [{"name": "offload", "min_version": "1.0.0"}],
  "required_capabilities": [],
  "vendor_features": []
}
JSON
}

make_valid_skill "$TMP_ROOT/valid-skill"
run_checker "$TMP_ROOT/valid-skill" "$TMP_ROOT/catalog.json"
[ "$CHECKER_EXIT" -eq 0 ] || fail 'vendor-neutral skill with optional adapter passes'
pass 'vendor-neutral skill with optional adapter passes'

cat > "$TMP_ROOT/empty-catalog.json" <<'JSON'
{
  "schema_version": 1,
  "adapter_contract_version": 1,
  "adapters": []
}
JSON
run_checker "$TMP_ROOT/valid-skill" "$TMP_ROOT/empty-catalog.json"
if [ "$CHECKER_EXIT" -eq 0 ] && [[ "$CHECKER_OUTPUT" == *'optional adapter'*'unavailable'* ]]; then
  :
else
  fail 'skill runs without optional adapter'
fi
pass 'skill runs without optional adapter'

make_valid_skill "$TMP_ROOT/missing-skill"
sed -i.bak 's/"imports": \[\]/"imports": [{"name": "missing-adapter", "min_version": "1.0.0"}]/' "$TMP_ROOT/missing-skill/publication.json"
rm -f "$TMP_ROOT/missing-skill/publication.json.bak"
run_checker "$TMP_ROOT/missing-skill" "$TMP_ROOT/catalog.json"
if [ "$CHECKER_EXIT" -ne 0 ] && [[ "$CHECKER_OUTPUT" == *"missing-adapter"*"unavailable"* ]]; then
  :
else
  fail 'required unavailable adapter fails'
fi
pass 'required unavailable adapter fails'

make_valid_skill "$TMP_ROOT/feature-skill"
sed -i.bak 's/"vendor_features": \[\]/"vendor_features": ["agy-launch"]/' "$TMP_ROOT/feature-skill/publication.json"
rm -f "$TMP_ROOT/feature-skill/publication.json.bak"
run_checker "$TMP_ROOT/feature-skill" "$TMP_ROOT/catalog.json"
if [ "$CHECKER_EXIT" -ne 0 ] && [[ "$CHECKER_OUTPUT" == *'vendor-specific feature'* ]]; then
  :
else
  fail 'vendor-specific feature declaration fails'
fi
pass 'vendor-specific feature declaration fails'

make_valid_skill "$TMP_ROOT/text-skill"
printf '%s\n' '# grill-with-docs' '' 'Requires Gemini model routing.' > "$TMP_ROOT/text-skill/SKILL.md"
run_checker "$TMP_ROOT/text-skill" "$TMP_ROOT/catalog.json"
if [ "$CHECKER_EXIT" -ne 0 ] && [[ "$CHECKER_OUTPUT" == *'vendor-specific reference'* ]]; then
  :
else
  fail 'vendor-specific text reference fails'
fi
pass 'vendor-specific text reference fails'

make_valid_skill "$TMP_ROOT/capability-skill"
sed -i.bak 's/"required_capabilities": \[\]/"required_capabilities": [{"adapter": "offload", "name": "missing-capability"}]/' "$TMP_ROOT/capability-skill/publication.json"
rm -f "$TMP_ROOT/capability-skill/publication.json.bak"
run_checker "$TMP_ROOT/capability-skill" "$TMP_ROOT/catalog.json"
if [ "$CHECKER_EXIT" -ne 0 ] && [[ "$CHECKER_OUTPUT" == *'missing-capability'* ]]; then
  :
else
  fail 'missing adapter capability fails'
fi
pass 'missing adapter capability fails'

printf '%s\n' 'all publication compatibility checks passed'
