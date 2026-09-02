#!/usr/bin/env bash
# tests/test_model_routing.sh
# Acceptance tests for Gemini model routing in scripts/run-agy-json.sh.
# Implements contracts specified in docs/specs/0003-gemini-model-routing.md.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAUNCHER="$ROOT/scripts/run-agy-json.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

[ -f "$LAUNCHER" ] || fail "Launcher script does not exist at $LAUNCHER"
bash -n "$LAUNCHER" || fail "Launcher script does not parse"
[ -x "$LAUNCHER" ] || fail "Launcher script is not executable"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-model-routing.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Setup fake agy executable
fake_bin="$TMP_ROOT/bin"
mkdir -p "$fake_bin"
fake_agy="$fake_bin/agy"

cat > "$fake_agy" <<'FAKE_AGY'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${FAKE_AGY_CANARY:-}" ]; then
  touch "$FAKE_AGY_CANARY"
fi

if [ -n "${FAKE_AGY_ARGS_FILE:-}" ]; then
  for arg in "$@"; do
    printf '%s\n' "$arg" >> "$FAKE_AGY_ARGS_FILE"
  done
fi

if [ -n "${FAKE_AGY_EXIT:-}" ]; then
  printf '%s\n' 'fake stderr' >&2
  exit "$FAKE_AGY_EXIT"
fi

printf '%s\n' 'fake stderr' >&2
printf '%s\n' '{"status":"success","response":"verbose worker text","structured_output":{"ok":true}}'
exit 0
FAKE_AGY
chmod +x "$fake_agy"

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT=0

invoke_launcher() {
  local script="${1:-$LAUNCHER}"
  shift
  local out_file="$TMP_ROOT/run_stdout.tmp"
  local err_file="$TMP_ROOT/run_stderr.tmp"
  rm -f "$out_file" "$err_file" "$TMP_ROOT/canary" "$TMP_ROOT/captured_args.txt"

  set +e
  FAKE_AGY_CANARY="$TMP_ROOT/canary" \
  FAKE_AGY_ARGS_FILE="$TMP_ROOT/captured_args.txt" \
  AGY_BIN="$fake_agy" \
  "$script" "$@" > "$out_file" 2> "$err_file"
  RUN_EXIT=$?
  set -e

  RUN_STDOUT=$(cat "$out_file" 2>/dev/null || true)
  RUN_STDERR=$(cat "$err_file" 2>/dev/null || true)
}

invoke_launcher_with_exit() {
  local exit_code="$1"
  shift
  local script="${1:-$LAUNCHER}"
  shift
  local out_file="$TMP_ROOT/run_stdout.tmp"
  local err_file="$TMP_ROOT/run_stderr.tmp"
  rm -f "$out_file" "$err_file" "$TMP_ROOT/canary" "$TMP_ROOT/captured_args.txt"

  set +e
  FAKE_AGY_CANARY="$TMP_ROOT/canary" \
  FAKE_AGY_ARGS_FILE="$TMP_ROOT/captured_args.txt" \
  FAKE_AGY_EXIT="$exit_code" \
  AGY_BIN="$fake_agy" \
  "$script" "$@" > "$out_file" 2> "$err_file"
  RUN_EXIT=$?
  set -e

  RUN_STDOUT=$(cat "$out_file" 2>/dev/null || true)
  RUN_STDERR=$(cat "$err_file" 2>/dev/null || true)
}

has_model_arg() {
  local expected="$1"
  local file="${2:-$TMP_ROOT/captured_args.txt}"
  local prev=""
  while IFS= read -r line; do
    if [ "$prev" = '--model' ] && [ "$line" = "$expected" ]; then
      return 0
    fi
    if [ "$line" = "--model=$expected" ]; then
      return 0
    fi
    prev="$line"
  done < "$file"
  return 1
}

count_model_args() {
  local file="${1:-$TMP_ROOT/captured_args.txt}"
  local count=0
  while IFS= read -r line; do
    if [ "$line" = '--model' ]; then
      count=$((count + 1))
    elif case "$line" in --model=*) true ;; *) false ;; esac; then
      count=$((count + 1))
    fi
  done < "$file"
  printf '%d\n' "$count"
}

has_exact_arg() {
  local expected="$1"
  local file="${2:-$TMP_ROOT/captured_args.txt}"
  while IFS= read -r line; do
    if [ "$line" = "$expected" ]; then
      return 0
    fi
  done < "$file"
  return 1
}

has_arg_pair() {
  local flag="$1"
  local val="$2"
  local file="${3:-$TMP_ROOT/captured_args.txt}"
  local prev=""
  while IFS= read -r line; do
    if [ "$prev" = "$flag" ] && [ "$line" = "$val" ]; then
      return 0
    fi
    prev="$line"
  done < "$file"
  return 1
}

create_fixture() {
  local fixture_dir="$1"
  mkdir -p "$fixture_dir/scripts"
  cp "$LAUNCHER" "$fixture_dir/scripts/run-agy-json.sh"
  chmod +x "$fixture_dir/scripts/run-agy-json.sh"
}

generate_valid_policy() {
  cat <<'EOF'
{
  "schema_version": 1,
  "policy_revision": "2026-09-03.1",
  "max_effort": "high",
  "max_retries_per_worker": 1,
  "quota_action": "handoff",
  "roles": {
    "scout": {
      "default_model": "gemini-3.8-flash-low",
      "quality_escalation": null
    },
    "gate-author": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    },
    "implementer": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    },
    "reviewer": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    },
    "researcher": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    },
    "synthesizer": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    },
    "auditor": {
      "default_model": "gemini-3.8-flash-high",
      "quality_escalation": null
    }
  }
}
EOF
}

# ===========================================================================
# 1. Every role resolves to exact initial model & default route
# ===========================================================================

roles=(
  "scout:gemini-3.8-flash-low"
  "gate-author:gemini-3.8-flash-high"
  "implementer:gemini-3.8-flash-high"
  "reviewer:gemini-3.8-flash-high"
  "researcher:gemini-3.8-flash-high"
  "synthesizer:gemini-3.8-flash-high"
  "auditor:gemini-3.8-flash-high"
)

for entry in "${roles[@]}"; do
  role="${entry%%:*}"
  expected_model="${entry##*:}"

  # Test omitted --route (defaults to 'default')
  out="$TMP_ROOT/role_${role}_out.json"
  err="$TMP_ROOT/role_${role}_err.log"
  invoke_launcher "$LAUNCHER" \
    --role "$role" \
    --output "$out" \
    --error "$err" \
    -- --prompt "test prompt for $role"
  [ "$RUN_EXIT" -eq 0 ] || fail "role $role failed to dispatch with omitted --route (exit $RUN_EXIT)"
  [ -f "$TMP_ROOT/canary" ] || fail "role $role did not invoke worker binary"
  [ "$(count_model_args)" -eq 1 ] || fail "role $role did not receive exactly one --model argument"
  has_model_arg "$expected_model" || fail "role $role did not resolve expected model $expected_model"
  ! has_exact_arg '--role' || fail "launcher leaked --role to worker for role $role"
  ! has_exact_arg '--route' || fail "launcher leaked --route to worker for role $role"

  # Test explicit --route default
  out_exp="$TMP_ROOT/role_${role}_exp_out.json"
  err_exp="$TMP_ROOT/role_${role}_exp_err.log"
  invoke_launcher "$LAUNCHER" \
    --role "$role" \
    --route default \
    --output "$out_exp" \
    --error "$err_exp" \
    -- --prompt "test prompt for $role default route"
  [ "$RUN_EXIT" -eq 0 ] || fail "role $role failed to dispatch with explicit --route default (exit $RUN_EXIT)"
  [ -f "$TMP_ROOT/canary" ] || fail "role $role did not invoke worker binary with explicit --route default"
  [ "$(count_model_args)" -eq 1 ] || fail "role $role did not receive exactly one --model argument with explicit --route default"
  has_model_arg "$expected_model" || fail "role $role did not resolve expected model $expected_model with explicit --route default"
done
pass 'every role resolves to exact initial model with default route (omitted and explicit)'

# ===========================================================================
# 2. Prompt/path preservation with spaces and --model/--effort text
# ===========================================================================

preserve_out="$TMP_ROOT/nested spaces/worker output.json"
preserve_err="$TMP_ROOT/nested spaces/worker error.log"
prompt_text='Investigate --model and --effort flags; verify --model=foo and --effort=high in text'
path_arg='docs/sub dir/path with spaces.txt'

invoke_launcher "$LAUNCHER" \
  --role implementer \
  --output "$preserve_out" \
  --error "$preserve_err" \
  -- \
  --prompt "$prompt_text" \
  --path "$path_arg"

[ "$RUN_EXIT" -eq 0 ] || fail "launcher rejected prompt containing --model and --effort strings (exit $RUN_EXIT)"
[ -f "$TMP_ROOT/canary" ] || fail "worker binary was not invoked for prompt preservation test"
[ "$(count_model_args)" -eq 1 ] || fail "launcher injected unexpected extra --model flag"
has_model_arg "gemini-3.8-flash-high" || fail "launcher did not inject implementer model"
has_arg_pair '--prompt' "$prompt_text" || fail "launcher failed to preserve prompt text containing --model and --effort"
has_arg_pair '--path' "$path_arg" || fail "launcher split or corrupted path argument containing spaces"
pass 'launcher preserves prompt and path arguments including prompt text containing --model and --effort'

# ===========================================================================
# 3. Rejection before worker start
# ===========================================================================

dummy_out="$TMP_ROOT/reject_out.json"
dummy_err="$TMP_ROOT/reject_err.log"

# 3.1 Missing --role
invoke_launcher "$LAUNCHER" \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'missing role'
[ "$RUN_EXIT" -eq 2 ] || fail "missing --role must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "missing --role must not invoke worker binary"
grep -Eiq 'role' <<< "$RUN_STDERR" || fail "missing --role must output diagnostic mentioning role"
pass 'launcher rejects missing --role before worker start'

# 3.2 Unknown role
invoke_launcher "$LAUNCHER" \
  --role 'unknown-role' \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'unknown role'
[ "$RUN_EXIT" -eq 2 ] || fail "unknown role must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "unknown role must not invoke worker binary"
grep -Eiq 'role' <<< "$RUN_STDERR" || fail "unknown role must output diagnostic mentioning role"
pass 'launcher rejects unknown role before worker start'

# 3.3 Unknown route
invoke_launcher "$LAUNCHER" \
  --role scout \
  --route 'invalid-route' \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'unknown route'
[ "$RUN_EXIT" -eq 2 ] || fail "unknown route must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "unknown route must not invoke worker binary"
grep -Eiq 'route' <<< "$RUN_STDERR" || fail "unknown route must output diagnostic mentioning route"
pass 'launcher rejects unknown route before worker start'

# 3.4 Caller --model override
invoke_launcher "$LAUNCHER" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --model 'gemini-3.8-flash-low' --prompt 'caller model'
[ "$RUN_EXIT" -eq 2 ] || fail "caller --model must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "caller --model must not invoke worker binary"
grep -Eiq 'model' <<< "$RUN_STDERR" || fail "caller --model must output diagnostic mentioning model"
pass 'launcher rejects caller --model option before worker start'

# 3.5 Caller --model=value override
invoke_launcher "$LAUNCHER" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --model=gemini-3.8-flash-low --prompt 'caller model equals'
[ "$RUN_EXIT" -eq 2 ] || fail "caller --model=value must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "caller --model=value must not invoke worker binary"
grep -Eiq 'model' <<< "$RUN_STDERR" || fail "caller --model=value must output diagnostic mentioning model"
pass 'launcher rejects caller --model=value option before worker start'

# 3.6 Caller --effort override
invoke_launcher "$LAUNCHER" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --effort high --prompt 'caller effort'
[ "$RUN_EXIT" -eq 2 ] || fail "caller --effort must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "caller --effort must not invoke worker binary"
grep -Eiq 'effort' <<< "$RUN_STDERR" || fail "caller --effort must output diagnostic mentioning effort"
pass 'launcher rejects caller --effort option before worker start'

# 3.7 Caller --effort=value override
invoke_launcher "$LAUNCHER" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --effort=high --prompt 'caller effort equals'
[ "$RUN_EXIT" -eq 2 ] || fail "caller --effort=value must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "caller --effort=value must not invoke worker binary"
grep -Eiq 'effort' <<< "$RUN_STDERR" || fail "caller --effort=value must output diagnostic mentioning effort"
pass 'launcher rejects caller --effort=value option before worker start'

# 3.8 Duplicate --role option
invoke_launcher "$LAUNCHER" \
  --role scout \
  --role implementer \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'duplicate role'
[ "$RUN_EXIT" -eq 2 ] || fail "duplicate --role must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "duplicate --role must not invoke worker binary"
grep -Eiq 'role' <<< "$RUN_STDERR" || fail "duplicate --role must output diagnostic mentioning role"
pass 'launcher rejects duplicate --role option before worker start'

# 3.9 Duplicate --route option
invoke_launcher "$LAUNCHER" \
  --role scout \
  --route default \
  --route default \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'duplicate route'
[ "$RUN_EXIT" -eq 2 ] || fail "duplicate --route must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "duplicate --route must not invoke worker binary"
grep -Eiq 'route' <<< "$RUN_STDERR" || fail "duplicate --route must output diagnostic mentioning route"
pass 'launcher rejects duplicate --route option before worker start'

# 3.10 Null quality-retry target
invoke_launcher "$LAUNCHER" \
  --role implementer \
  --route quality-retry \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'null quality retry'
[ "$RUN_EXIT" -eq 2 ] || fail "null quality-retry target must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "null quality-retry target must not invoke worker binary"
grep -Eiq 'escalat|retry|target' <<< "$RUN_STDERR" || fail "null quality-retry must output diagnostic"

invoke_launcher "$LAUNCHER" \
  --role scout \
  --route quality-retry \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'null quality retry scout'
[ "$RUN_EXIT" -eq 2 ] || fail "null quality-retry target on scout must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "null quality-retry target on scout must not invoke worker binary"
pass 'launcher rejects null quality-retry target before worker start'

# ===========================================================================
# 4. Missing, malformed, and invalid model-policy.json rejection
# ===========================================================================

# 4.1 Missing model-policy.json
fix_missing="$TMP_ROOT/fix_missing"
create_fixture "$fix_missing"
invoke_launcher "$fix_missing/scripts/run-agy-json.sh" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "missing model-policy.json must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "missing model-policy.json must not invoke worker binary"
grep -Eiq 'policy' <<< "$RUN_STDERR" || fail "missing policy diagnostic expected"
pass 'launcher rejects missing model-policy.json before worker start'

# 4.2 Malformed JSON
fix_malformed="$TMP_ROOT/fix_malformed"
create_fixture "$fix_malformed"
printf '{ "schema_version": 1, invalid_json\n' > "$fix_malformed/model-policy.json"
invoke_launcher "$fix_malformed/scripts/run-agy-json.sh" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "malformed model-policy.json must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "malformed model-policy.json must not invoke worker binary"
pass 'launcher rejects malformed JSON in model-policy.json before worker start'

# 4.3 Unsupported schema_version (integer 2)
fix_bad_ver="$TMP_ROOT/fix_bad_ver"
create_fixture "$fix_bad_ver"
generate_valid_policy | jq '.schema_version = 2' > "$fix_bad_ver/model-policy.json"
invoke_launcher "$fix_bad_ver/scripts/run-agy-json.sh" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "unsupported schema_version must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "unsupported schema_version must not invoke worker binary"
pass 'launcher rejects unsupported schema_version before worker start'

# 4.4 Non-integer schema_version (string "1")
fix_str_ver="$TMP_ROOT/fix_str_ver"
create_fixture "$fix_str_ver"
generate_valid_policy | jq '.schema_version = "1"' > "$fix_str_ver/model-policy.json"
invoke_launcher "$fix_str_ver/scripts/run-agy-json.sh" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "non-integer schema_version must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "non-integer schema_version must not invoke worker binary"
pass 'launcher rejects non-integer schema_version before worker start'

# 4.5 Missing required top-level field (max_effort)
fix_missing_field="$TMP_ROOT/fix_missing_field"
create_fixture "$fix_missing_field"
generate_valid_policy | jq 'del(.max_effort)' > "$fix_missing_field/model-policy.json"
invoke_launcher "$fix_missing_field/scripts/run-agy-json.sh" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "missing max_effort must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "missing max_effort must not invoke worker binary"
pass 'launcher rejects policy missing required top-level field before worker start'

# 4.6 Invalid top-level value (max_effort = "ultra")
fix_bad_effort="$TMP_ROOT/fix_bad_effort"
create_fixture "$fix_bad_effort"
generate_valid_policy | jq '.max_effort = "ultra"' > "$fix_bad_effort/model-policy.json"
invoke_launcher "$fix_bad_effort/scripts/run-agy-json.sh" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "invalid max_effort must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "invalid max_effort must not invoke worker binary"
pass 'launcher rejects policy with invalid max_effort before worker start'

# 4.7 Missing required role (missing 'auditor')
fix_missing_role="$TMP_ROOT/fix_missing_role"
create_fixture "$fix_missing_role"
generate_valid_policy | jq 'del(.roles.auditor)' > "$fix_missing_role/model-policy.json"
invoke_launcher "$fix_missing_role/scripts/run-agy-json.sh" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "policy missing required role must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "policy missing required role must not invoke worker binary"
pass 'launcher rejects policy missing required role before worker start'

# 4.8 Non-Gemini model ID
fix_non_gemini="$TMP_ROOT/fix_non_gemini"
create_fixture "$fix_non_gemini"
generate_valid_policy | jq '.roles.scout.default_model = "claude-3-7-sonnet"' > "$fix_non_gemini/model-policy.json"
invoke_launcher "$fix_non_gemini/scripts/run-agy-json.sh" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "non-Gemini model ID must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "non-Gemini model ID must not invoke worker binary"
pass 'launcher rejects non-Gemini model ID before worker start'

# 4.9 Unknown / invalid effort suffix
fix_bad_suffix="$TMP_ROOT/fix_bad_suffix"
create_fixture "$fix_bad_suffix"
generate_valid_policy | jq '.roles.scout.default_model = "gemini-3.8-flash-ultra"' > "$fix_bad_suffix/model-policy.json"
invoke_launcher "$fix_bad_suffix/scripts/run-agy-json.sh" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "unknown effort suffix must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "unknown effort suffix must not invoke worker binary"
pass 'launcher rejects unknown effort suffix before worker start'

# 4.10 Empty model ID
fix_empty_model="$TMP_ROOT/fix_empty_model"
create_fixture "$fix_empty_model"
generate_valid_policy | jq '.roles.scout.default_model = ""' > "$fix_empty_model/model-policy.json"
invoke_launcher "$fix_empty_model/scripts/run-agy-json.sh" \
  --role scout \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "empty model ID must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "empty model ID must not invoke worker binary"
pass 'launcher rejects empty model ID before worker start'

# 4.11 Escalation target with missing evidence path
fix_missing_evidence="$TMP_ROOT/fix_missing_evidence"
create_fixture "$fix_missing_evidence"
generate_valid_policy | jq '.roles.implementer.quality_escalation = {"model":"gemini-3.8-flash-medium","evidence_path":"docs/evaluations/nonexistent.md"}' > "$fix_missing_evidence/model-policy.json"
invoke_launcher "$fix_missing_evidence/scripts/run-agy-json.sh" \
  --role implementer \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "missing escalation evidence path must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "missing escalation evidence path must not invoke worker binary"
pass 'launcher rejects escalation target with missing evidence path before worker start'

# 4.12 Escalation target with escaping evidence path (parent traversal)
fix_escaping_evidence="$TMP_ROOT/fix_escaping_evidence"
create_fixture "$fix_escaping_evidence"
generate_valid_policy | jq '.roles.implementer.quality_escalation = {"model":"gemini-3.8-flash-medium","evidence_path":"../outside.md"}' > "$fix_escaping_evidence/model-policy.json"
invoke_launcher "$fix_escaping_evidence/scripts/run-agy-json.sh" \
  --role implementer \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "escaping escalation evidence path must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "escaping escalation evidence path must not invoke worker binary"
pass 'launcher rejects escalation target with escaping evidence path before worker start'

# 4.13 Escalation target model identical to default model
fix_identical_model="$TMP_ROOT/fix_identical_model"
create_fixture "$fix_identical_model"
mkdir -p "$fix_identical_model/docs"
printf 'evidence\n' > "$fix_identical_model/docs/evidence.md"
generate_valid_policy | jq '.roles.implementer.quality_escalation = {"model":"gemini-3.8-flash-high","evidence_path":"docs/evidence.md"}' > "$fix_identical_model/model-policy.json"
invoke_launcher "$fix_identical_model/scripts/run-agy-json.sh" \
  --role implementer \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'test'
[ "$RUN_EXIT" -eq 2 ] || fail "identical escalation model must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "identical escalation model must not invoke worker binary"
pass 'launcher rejects escalation target model identical to default model before worker start'

# ===========================================================================
# 5. Fixture policy with a valid evidence-backed escalation target
# ===========================================================================

fix_valid_escalation="$TMP_ROOT/fix_valid_escalation"
create_fixture "$fix_valid_escalation"
mkdir -p "$fix_valid_escalation/docs/evaluations"
cat > "$fix_valid_escalation/docs/evaluations/implementer-eval.md" <<'EOF'
# Implementer Evaluation
Role: implementer
Baseline: gemini-3.8-flash-high
Candidate: gemini-3.8-flash-medium
Comparison method: benchmark gates
Results: verified task success demonstrated
Promotion decision: escalation approved
EOF

generate_valid_policy | jq '.roles.implementer.quality_escalation = {
  "model": "gemini-3.8-flash-medium",
  "evidence_path": "docs/evaluations/implementer-eval.md"
}' > "$fix_valid_escalation/model-policy.json"

# 5.1 Dispatches configured escalation target on quality-retry route
escl_out="$TMP_ROOT/escl_out.json"
escl_err="$TMP_ROOT/escl_err.log"
invoke_launcher "$fix_valid_escalation/scripts/run-agy-json.sh" \
  --role implementer \
  --route quality-retry \
  --output "$escl_out" \
  --error "$escl_err" \
  -- --prompt 'escalation run'
[ "$RUN_EXIT" -eq 0 ] || fail "quality-retry dispatch failed (exit $RUN_EXIT)"
[ -f "$TMP_ROOT/canary" ] || fail "worker binary was not invoked on quality-retry"
[ "$(count_model_args)" -eq 1 ] || fail "expected exactly one --model on quality-retry"
has_model_arg "gemini-3.8-flash-medium" || fail "quality-retry did not dispatch escalation model gemini-3.8-flash-medium"

# 5.2 Dispatches default model on default route on same fixture
default_out="$TMP_ROOT/default_out.json"
default_err="$TMP_ROOT/default_err.log"
invoke_launcher "$fix_valid_escalation/scripts/run-agy-json.sh" \
  --role implementer \
  --route default \
  --output "$default_out" \
  --error "$default_err" \
  -- --prompt 'default route run'
[ "$RUN_EXIT" -eq 0 ] || fail "default route dispatch failed (exit $RUN_EXIT)"
[ -f "$TMP_ROOT/canary" ] || fail "worker binary was not invoked on default route"
[ "$(count_model_args)" -eq 1 ] || fail "expected exactly one --model on default route"
has_model_arg "gemini-3.8-flash-high" || fail "default route did not dispatch default model gemini-3.8-flash-high"

# 5.3 Dispatches default model on omitted route on same fixture
omit_out="$TMP_ROOT/omit_out.json"
omit_err="$TMP_ROOT/omit_err.log"
invoke_launcher "$fix_valid_escalation/scripts/run-agy-json.sh" \
  --role implementer \
  --output "$omit_out" \
  --error "$omit_err" \
  -- --prompt 'omitted route run'
[ "$RUN_EXIT" -eq 0 ] || fail "omitted route dispatch failed (exit $RUN_EXIT)"
[ -f "$TMP_ROOT/canary" ] || fail "worker binary was not invoked on omitted route"
[ "$(count_model_args)" -eq 1 ] || fail "expected exactly one --model on omitted route"
has_model_arg "gemini-3.8-flash-high" || fail "omitted route did not dispatch default model gemini-3.8-flash-high"

# 5.4 Reject quality-retry on a role whose escalation target remains null on same fixture
invoke_launcher "$fix_valid_escalation/scripts/run-agy-json.sh" \
  --role scout \
  --route quality-retry \
  --output "$dummy_out" \
  --error "$dummy_err" \
  -- --prompt 'null target run'
[ "$RUN_EXIT" -eq 2 ] || fail "quality-retry on role with null target must fail with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "worker binary must not be invoked for null quality-retry"
pass 'launcher dispatches valid evidence-backed escalation target on quality-retry and default model on default route'

# ===========================================================================
# 6. Preserved launcher contract checks
# ===========================================================================

contract_out="$TMP_ROOT/contract_out.json"
contract_err="$TMP_ROOT/contract_err.log"

# 6.1 Output capture and separation (worker stdout to --output, worker stderr to --error, launcher stdout empty)
invoke_launcher "$LAUNCHER" \
  --role scout \
  --output "$contract_out" \
  --error "$contract_err" \
  -- --prompt 'capture test' --output-format json
[ "$RUN_EXIT" -eq 0 ] || fail "contract capture run failed (exit $RUN_EXIT)"
[ -z "$RUN_STDOUT" ] || fail "launcher leaked worker output to stdout"
[ -f "$contract_out" ] || fail "launcher did not create output file"
[ -f "$contract_err" ] || fail "launcher did not create error file"
[ "$(jq -r '.structured_output.ok' "$contract_out")" = true ] || fail "launcher did not preserve worker JSON output"
[ "$(cat "$contract_err")" = 'fake stderr' ] || fail "launcher did not preserve worker stderr"
pass 'launcher preserves output capture and stream separation'

# 6.2 Worker exit code propagation
invoke_launcher_with_exit 42 "$LAUNCHER" \
  --role scout \
  --output "$contract_out" \
  --error "$contract_err" \
  -- --prompt 'exit code test'
[ "$RUN_EXIT" -eq 42 ] || fail "launcher did not propagate worker exit code 42 (got $RUN_EXIT)"
pass 'launcher propagates non-zero worker exit code'

# 6.3 Required delimiter rejection (missing '--')
invoke_launcher "$LAUNCHER" \
  --role scout \
  --output "$contract_out" \
  --error "$contract_err" \
  --prompt 'missing delimiter'
[ "$RUN_EXIT" -eq 2 ] || fail "launcher must reject missing delimiter '--' with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "launcher must not invoke worker binary when delimiter is missing"
pass 'launcher rejects missing required delimiter'

# 6.4 Forwarded --output rejection
invoke_launcher "$LAUNCHER" \
  --role scout \
  --output "$contract_out" \
  --error "$contract_err" \
  -- --output "$TMP_ROOT/worker_owned.json"
[ "$RUN_EXIT" -eq 2 ] || fail "launcher must reject forwarded --output flag with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "launcher must not invoke worker binary on forwarded --output"

invoke_launcher "$LAUNCHER" \
  --role scout \
  --output "$contract_out" \
  --error "$contract_err" \
  -- --output="$TMP_ROOT/worker_owned.json"
[ "$RUN_EXIT" -eq 2 ] || fail "launcher must reject forwarded --output=value flag with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "launcher must not invoke worker binary on forwarded --output=value"
pass 'launcher rejects forwarded --output and --output=value flags'

# 6.5 Missing required paths (--output or --error)
invoke_launcher "$LAUNCHER" \
  --role scout \
  --error "$contract_err" \
  -- --prompt 'missing output path'
[ "$RUN_EXIT" -eq 2 ] || fail "launcher must reject missing --output path with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "launcher must not invoke worker binary when --output is missing"

invoke_launcher "$LAUNCHER" \
  --role scout \
  --output "$contract_out" \
  -- --prompt 'missing error path'
[ "$RUN_EXIT" -eq 2 ] || fail "launcher must reject missing --error path with exit code 2 (got $RUN_EXIT)"
[ ! -f "$TMP_ROOT/canary" ] || fail "launcher must not invoke worker binary when --error is missing"
pass 'launcher rejects missing --output and --error paths'

# 6.6 Invalid explicit AGY_BIN fails without fallback
set +e
invalid_out="$TMP_ROOT/invalid_out.json"
invalid_err="$TMP_ROOT/invalid_err.log"
rm -f "$TMP_ROOT/canary"
AGY_BIN="$TMP_ROOT/nonexistent-binary" \
  "$LAUNCHER" \
  --role scout \
  --output "$invalid_out" \
  --error "$invalid_err" \
  -- --prompt 'invalid bin' 2>/dev/null
invalid_exit=$?
set -e
[ "$invalid_exit" -ne 0 ] || fail "launcher succeeded when explicit AGY_BIN was invalid"
[ ! -e "$invalid_out" ] || fail "launcher ran worker output when AGY_BIN was invalid"
pass 'launcher fails without fallback when explicit AGY_BIN is invalid'

printf '%s\n' 'all gemini model routing acceptance checks passed'
