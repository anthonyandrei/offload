#!/usr/bin/env bash
# scripts/execution-workspace.sh
# Platform-agnostic execution workspace lifecycle manager for Bash 3.2+.
# Manages isolated git worktrees for workers: create, verify-export, integrate, cleanup.

set -euo pipefail

MARKER_NAME=".offload-execution-workspace"
MARKER_CONTENT="offload-execution-workspace-v1"
MANIFEST_MARKER="offload-execution-manifest-v1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OFFLOAD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SCOPE_CHECKER="$SCRIPT_DIR/check-execution-scope.sh"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  cat <<'EOF' >&2
Usage:
  execution-workspace.sh create --source-repo <path> --task-id <id> --baseline <rev> --owned <path> [--owned <path> ...] [--frozen <path> ...] [--manifest <path>] [--workspace-dir <path>]
  execution-workspace.sh verify-export --manifest <path> [--patch-output <path>]
  execution-workspace.sh integrate --manifest <path> [--target-repo <path>]
  execution-workspace.sh cleanup --manifest <path> [--status <success|failed|retain>]

Commands:
  create           Create an isolated Git worktree and external manifest for a task
  verify-export    Verify candidate scope, export unified binary patch, record SHA-256 digest
  integrate        Preflight in disposable integration checkout and apply verified patch
  cleanup          Safely remove manifest-owned worktree and artifacts
EOF
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

canonicalize_path() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd "$p" 2>/dev/null && pwd -P)
  elif [ -f "$p" ]; then
    local dir base
    dir="$(dirname "$p")"
    base="$(basename "$p")"
    local cdir
    cdir="$(cd "$dir" 2>/dev/null && pwd -P)"
    printf '%s/%s' "$cdir" "$base"
  else
    local dir base
    dir="$(dirname "$p")"
    base="$(basename "$p")"
    if [ -d "$dir" ]; then
      local cdir
      cdir="$(cd "$dir" 2>/dev/null && pwd -P)"
      printf '%s/%s' "$cdir" "$base"
    else
      printf '%s' "$p"
    fi
  fi
}

path_is_within() {
  local child parent
  child="$(canonicalize_path "$1")"
  parent="$(canonicalize_path "$2")"
  [ "$child" = "$parent" ] || case "$child" in
    "$parent"/*) return 0 ;;
  esac
  return 1
}

normalize_rel_path() {
  local p="$1"
  p="${p//\\//}"
  while [[ "$p" == ./* ]]; do
    p="${p#./}"
  done
  while [[ "$p" == /* && "$p" != "/" ]]; do
    p="${p#/}"
  done
  while [[ "$p" == */ && "$p" != "/" ]]; do
    p="${p%/}"
  done
  if [[ "$p" == "." || "$p" == "/" ]]; then
    p=""
  fi
  printf '%s' "$p"
}

compute_sha256() {
  local target_file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$target_file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$target_file" | awk '{print $1}'
  else
    fail "no SHA-256 utility found (requires sha256sum or shasum)"
  fi
}

get_iso_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ"
}

# Extracts a top-level string field from a JSON file without requiring jq
json_extract_string() {
  local file="$1"
  local key="$2"
  local val
  if command -v jq >/dev/null 2>&1; then
    val="$(jq -r --arg k "$key" '.[$k] // empty' "$file")"
  else
    # Fallback portable regex parser for simple top-level keys
    val="$(sed -n -e 's/^[[:space:]]*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)"
  fi
  printf '%s' "$val" | tr -d '\r'
}

# Extracts an array of strings from a JSON file
json_extract_array() {
  local file="$1"
  local key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k][]? // empty' "$file" | tr -d '\r'
  else
    # Fallback for simple single-line or multi-line array of strings
    awk -v key="\"$key\"" '
      $0 ~ key { in_arr=1; next }
      in_arr && /\]/ { in_arr=0 }
      in_arr {
        match($0, /"([^"]+)"/, arr)
        if (arr[1] != "") print arr[1]
      }
    ' "$file" | tr -d '\r'
  fi
}

# ---------------------------------------------------------------------------
# Command: create
# ---------------------------------------------------------------------------
cmd_create() {
  local source_repo=""
  local task_id=""
  local baseline=""
  local owned=()
  local frozen=()
  local manifest_path=""
  local workspace_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --source-repo)
        [ $# -ge 2 ] || fail "--source-repo requires a path"
        source_repo="$2"
        shift 2
        ;;
      --source-repo=*)
        source_repo="${1#*=}"
        shift
        ;;
      --task-id)
        [ $# -ge 2 ] || fail "--task-id requires a value"
        task_id="$2"
        shift 2
        ;;
      --task-id=*)
        task_id="${1#*=}"
        shift
        ;;
      --baseline)
        [ $# -ge 2 ] || fail "--baseline requires a value"
        baseline="$2"
        shift 2
        ;;
      --baseline=*)
        baseline="${1#*=}"
        shift
        ;;
      --owned)
        [ $# -ge 2 ] || fail "--owned requires a path"
        owned+=("$2")
        shift 2
        ;;
      --owned=*)
        owned+=("${1#*=}")
        shift
        ;;
      --frozen)
        [ $# -ge 2 ] || fail "--frozen requires a path"
        frozen+=("$2")
        shift 2
        ;;
      --frozen=*)
        frozen+=("${1#*=}")
        shift
        ;;
      --manifest)
        [ $# -ge 2 ] || fail "--manifest requires a path"
        manifest_path="$2"
        shift 2
        ;;
      --manifest=*)
        manifest_path="${1#*=}"
        shift
        ;;
      --workspace-dir)
        [ $# -ge 2 ] || fail "--workspace-dir requires a path"
        workspace_dir="$2"
        shift 2
        ;;
      --workspace-dir=*)
        workspace_dir="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unrecognized argument for create: $1"
        ;;
    esac
  done

  [ -n "$source_repo" ] || fail "--source-repo is required"
  [ -n "$task_id" ] || fail "--task-id is required"
  [ -n "$baseline" ] || fail "--baseline is required"
  [ "${#owned[@]}" -gt 0 ] || fail "at least one --owned path is required"

  # Validate task_id characters
  if [[ ! "$task_id" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    fail "task-id must contain only alphanumeric characters, dots, underscores, or dashes: $task_id"
  fi

  # Validate source repository
  [ -d "$source_repo" ] || fail "source repository directory does not exist: $source_repo"
  local canon_repo
  canon_repo="$(canonicalize_path "$source_repo")"
  if ! git -C "$canon_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "source repository is not a git worktree: $source_repo"
  fi

  # Validate baseline
  local resolved_baseline
  if ! resolved_baseline="$(git -C "$canon_repo" rev-parse --verify "${baseline}^{commit}" 2>/dev/null)"; then
    fail "baseline revision does not resolve to a commit: $baseline"
  fi
  resolved_baseline="$(printf '%s' "$resolved_baseline" | tr -d '\r\n')"

  # Validate owned and frozen paths
  local norm_owned=()
  for o in "${owned[@]}"; do
    local no
    no="$(normalize_rel_path "$o")"
    [ -n "$no" ] || fail "owned path cannot be empty or root: $o"
    if [[ "$no" == *".."* ]]; then
      fail "owned path escapes repository: $o"
    fi
    norm_owned+=("$no")
  done

  local norm_frozen=()
  if [ "${#frozen[@]}" -gt 0 ]; then
    for f in "${frozen[@]}"; do
      local nf
      nf="$(normalize_rel_path "$f")"
      [ -n "$nf" ] || fail "frozen path cannot be empty or root: $f"
      if [[ "$nf" == *".."* ]]; then
        fail "frozen path escapes repository: $f"
      fi
      norm_frozen+=("$nf")
    done
  fi

  # Determine workspace directory
  if [ -z "$workspace_dir" ]; then
    local tmp_base="${TMPDIR:-/tmp}/offload-exec-$task_id-XXXXXX"
    workspace_dir="$(mktemp -d "$tmp_base")/checkout"
  fi

  local canon_workspace
  canon_workspace="$(canonicalize_path "$workspace_dir")"

  # Ensure workspace dir does not conflict with repo or roots
  if [ "$canon_workspace" = "$canon_repo" ]; then
    fail "workspace directory cannot be the source repository: $workspace_dir"
  fi
  local cwd_phys
  cwd_phys="$(pwd -P)"
  if [ "$canon_workspace" = "$cwd_phys" ]; then
    fail "workspace directory cannot be process current directory: $workspace_dir"
  fi
  if [ "$canon_workspace" = "/" ] || [[ "$canon_workspace" =~ ^[a-zA-Z]:[/\\]?$ ]]; then
    fail "workspace directory cannot be filesystem root: $workspace_dir"
  fi
  if [ -n "${HOME:-}" ] && [ "$canon_workspace" = "$(canonicalize_path "$HOME")" ]; then
    fail "workspace directory cannot be user home directory: $workspace_dir"
  fi
  if [ -n "${USERPROFILE:-}" ] && [ "$canon_workspace" = "$(canonicalize_path "$USERPROFILE")" ]; then
    fail "workspace directory cannot be user profile directory: $workspace_dir"
  fi

  # Determine manifest path
  if [ -z "$manifest_path" ]; then
    local ws_parent
    ws_parent="$(dirname "$canon_workspace")"
    manifest_path="$ws_parent/$task_id.manifest.json"
  fi

  local canon_manifest
  canon_manifest="$(canonicalize_path "$manifest_path")"

  # Manifest must NOT be inside the worker checkout
  if [[ "$canon_manifest" == "$canon_workspace/"* || "$canon_manifest" == "$canon_workspace" ]]; then
    fail "manifest path must be outside the worker checkout: $manifest_path"
  fi

  mkdir -p "$(dirname "$canon_manifest")"
  mkdir -p "$(dirname "$canon_workspace")"

  # If workspace dir exists and is non-empty, fail
  if [ -d "$canon_workspace" ] && [ "$(ls -A "$canon_workspace" 2>/dev/null | wc -l)" -gt 0 ]; then
    fail "workspace directory already exists and is not empty: $workspace_dir"
  fi

  # Create Git worktree
  if ! git -C "$canon_repo" worktree add --detach "$canon_workspace" "$resolved_baseline" >/dev/null 2>&1; then
    fail "failed to create git worktree at $canon_workspace from baseline $resolved_baseline"
  fi

  # Write workspace marker
  printf '%s\n' "$MARKER_CONTENT" > "$canon_workspace/$MARKER_NAME"

  # Ensure marker is in git exclude so it is not treated as an untracked change
  local exclude_file
  exclude_file="$(git -C "$canon_repo" rev-parse --git-path info/exclude 2>/dev/null || true)"
  if [ -n "$exclude_file" ]; then
    if [[ "$exclude_file" != /* && ! "$exclude_file" =~ ^[a-zA-Z]: ]]; then
      exclude_file="$canon_repo/$exclude_file"
    fi
    mkdir -p "$(dirname "$exclude_file")"
    if [ ! -f "$exclude_file" ] || ! grep -q "^$MARKER_NAME$" "$exclude_file" 2>/dev/null; then
      printf '\n%s\n' "$MARKER_NAME" >> "$exclude_file"
    fi
  fi

  # Build JSON manifest
  local created_at
  created_at="$(get_iso_timestamp)"

  local owned_json=""
  local first=true
  for o in "${norm_owned[@]}"; do
    if $first; then
      owned_json="\"$o\""
      first=false
    else
      owned_json="$owned_json, \"$o\""
    fi
  done

  local frozen_json=""
  first=true
  if [ "${#norm_frozen[@]}" -gt 0 ]; then
    for f in "${norm_frozen[@]}"; do
      if $first; then
        frozen_json="\"$f\""
        first=false
      else
        frozen_json="$frozen_json, \"$f\""
      fi
    done
  fi

  cat <<EOF > "$canon_manifest"
{
  "schema_version": 1,
  "marker": "$MANIFEST_MARKER",
  "task_id": "$task_id",
  "source_repo": "$canon_repo",
  "workspace_dir": "$canon_workspace",
  "manifest_path": "$canon_manifest",
  "baseline": "$resolved_baseline",
  "owned_paths": [$owned_json],
  "frozen_paths": [$frozen_json],
  "status": "created",
  "created_at": "$created_at"
}
EOF

  printf '%s\n' "$canon_workspace"
}

# ---------------------------------------------------------------------------
# Command: verify-export
# ---------------------------------------------------------------------------
cmd_verify_export() {
  local manifest_path=""
  local patch_output=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --manifest)
        [ $# -ge 2 ] || fail "--manifest requires a path"
        manifest_path="$2"
        shift 2
        ;;
      --manifest=*)
        manifest_path="${1#*=}"
        shift
        ;;
      --patch-output)
        [ $# -ge 2 ] || fail "--patch-output requires a path"
        patch_output="$2"
        shift 2
        ;;
      --patch-output=*)
        patch_output="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unrecognized argument for verify-export: $1"
        ;;
    esac
  done

  [ -n "$manifest_path" ] || fail "--manifest is required"
  local canon_manifest
  canon_manifest="$(canonicalize_path "$manifest_path")"
  [ -f "$canon_manifest" ] || fail "manifest file does not exist: $manifest_path"

  local marker
  marker="$(json_extract_string "$canon_manifest" "marker")"
  [ "$marker" = "$MANIFEST_MARKER" ] || fail "invalid manifest marker in $manifest_path"

  local task_id workspace_dir source_repo baseline
  task_id="$(json_extract_string "$canon_manifest" "task_id")"
  workspace_dir="$(json_extract_string "$canon_manifest" "workspace_dir")"
  source_repo="$(json_extract_string "$canon_manifest" "source_repo")"
  baseline="$(json_extract_string "$canon_manifest" "baseline")"

  [ -d "$workspace_dir" ] || fail "candidate workspace directory does not exist: $workspace_dir"
  [ -f "$workspace_dir/$MARKER_NAME" ] || fail "candidate directory lacks execution workspace marker: $workspace_dir"

  local marker_val
  marker_val="$(tr -d '\r\n' < "$workspace_dir/$MARKER_NAME")"
  [ "$marker_val" = "$MARKER_CONTENT" ] || fail "invalid execution workspace marker content in $workspace_dir"

  # Extract owned and frozen paths
  local owned_paths=()
  while IFS= read -r line; do
    [ -n "$line" ] && owned_paths+=("$line")
  done < <(json_extract_array "$canon_manifest" "owned_paths")

  local frozen_paths=()
  while IFS= read -r line; do
    [ -n "$line" ] && frozen_paths+=("$line")
  done < <(json_extract_array "$canon_manifest" "frozen_paths")

  [ "${#owned_paths[@]}" -gt 0 ] || fail "manifest contains no owned paths"

  # The review artifact must live outside the candidate so the worker cannot
  # change the evidence after export.
  if [ -z "$patch_output" ]; then
    local mdir
    mdir="$(dirname "$canon_manifest")"
    patch_output="$mdir/$task_id.patch"
  fi
  local canon_patch
  canon_patch="$(canonicalize_path "$patch_output")"
  if path_is_within "$canon_patch" "$workspace_dir"; then
    fail "patch output must be outside candidate workspace: $patch_output"
  fi

  # 1. Scope check execution: run check-execution-scope against candidate worktree
  local scope_args=("--baseline" "$baseline")
  for o in "${owned_paths[@]}"; do
    scope_args+=("--owned" "$o")
  done
  if [ "${#frozen_paths[@]}" -gt 0 ]; then
    for f in "${frozen_paths[@]}"; do
      scope_args+=("--frozen" "$f")
    done
  fi

  local scope_exit=0
  local scope_out=""
  set +e
  scope_out=$(cd "$workspace_dir" && "$SCOPE_CHECKER" "${scope_args[@]}" 2>&1)
  scope_exit=$?
  set -e

  if [ "$scope_exit" -ne 0 ]; then
    printf 'Error: execution scope check failed for candidate %s:\n%s\n' "$task_id" "$scope_out" >&2
    exit "$scope_exit"
  fi

  # 2. Stage all changes (including untracked and deletions) to ensure uncommitted changes are captured
  git -C "$workspace_dir" add -A

  mkdir -p "$(dirname "$canon_patch")"

  # Generate binary diff from baseline
  if ! git -C "$workspace_dir" diff --cached --find-renames -p --binary "$baseline" --output "$canon_patch"; then
    fail "failed to export git diff from baseline $baseline"
  fi

  # Check that patch file exists
  [ -f "$canon_patch" ] || fail "failed to produce patch file at $canon_patch"

  # 3. Compute content digest
  local hex_digest
  hex_digest="$(compute_sha256 "$canon_patch")"
  local patch_digest="sha256:$hex_digest"

  # 4. Verify that the exported patch touches only owned paths and no frozen paths
  local touched_files=()
  # Read the exact staged status record so renames retain both paths and
  # artifact coverage matches the exported patch.
  local names_file
  names_file="$(mktemp "${TMPDIR:-/tmp}/execution-workspace.names.XXXXXX")"
  if ! git -C "$workspace_dir" diff --cached --name-status -z --find-renames "$baseline" >"$names_file"; then
    rm -f "$names_file"
    fail "failed to list exported paths from baseline $baseline"
  fi
  local -a name_tokens=()
  while IFS= read -r -d '' token; do
    name_tokens+=("$token")
  done < "$names_file"
  rm -f "$names_file"
  local name_index=0
  while [ "$name_index" -lt "${#name_tokens[@]}" ]; do
    local diff_status="${name_tokens[$name_index]}"
    local path_index=$((name_index + 1))
    [ "$path_index" -lt "${#name_tokens[@]}" ] || fail "malformed NUL-delimited git diff output"
    local tf="${name_tokens[$path_index]}"
    tf="$(normalize_rel_path "$tf")"
    [ -n "$tf" ] || fail "malformed NUL-delimited git diff path"
    touched_files+=("$tf")
    name_index=$((name_index + 2))
    if [[ "$diff_status" == R* || "$diff_status" == C* ]]; then
      [ "$name_index" -lt "${#name_tokens[@]}" ] || fail "malformed NUL-delimited git rename output"
      local rename_target
      rename_target="$(normalize_rel_path "${name_tokens[$name_index]}")"
      [ -n "$rename_target" ] || fail "malformed NUL-delimited git rename path"
      touched_files+=("$rename_target")
      name_index=$((name_index + 1))
    fi
  done

  for tf in ${touched_files[@]+"${touched_files[@]}"}; do
    # Check frozen
    for f in ${frozen_paths[@]+"${frozen_paths[@]}"}; do
      if [ "$tf" = "$f" ] || [[ "$tf" == "$f/"* ]]; then
        fail "exported diff touches frozen path: $tf"
      fi
    done
    # Check owned
    local is_owned=false
    for o in "${owned_paths[@]}"; do
      if [ "$tf" = "$o" ] || [[ "$tf" == "$o/"* ]]; then
        is_owned=true
        break
      fi
    done
    if ! $is_owned; then
      fail "exported diff touches unowned path: $tf"
    fi
  done

  # 5. Update manifest with export details
  local exported_at
  exported_at="$(get_iso_timestamp)"

  local touched_json=""
  local first=true
  for tf in ${touched_files[@]+"${touched_files[@]}"}; do
    if $first; then
      touched_json="\"$tf\""
      first=false
    else
      touched_json="$touched_json, \"$tf\""
    fi
  done

  # Rewrite or update manifest JSON
  local owned_json=""
  first=true
  for o in "${owned_paths[@]}"; do
    if $first; then
      owned_json="\"$o\""
      first=false
    else
      owned_json="$owned_json, \"$o\""
    fi
  done

  local frozen_json=""
  first=true
  if [ "${#frozen_paths[@]}" -gt 0 ]; then
    for f in "${frozen_paths[@]}"; do
      if $first; then
        frozen_json="\"$f\""
        first=false
      else
        frozen_json="$frozen_json, \"$f\""
      fi
    done
  fi

  cat <<EOF > "$canon_manifest"
{
  "schema_version": 1,
  "marker": "$MANIFEST_MARKER",
  "task_id": "$task_id",
  "source_repo": "$source_repo",
  "workspace_dir": "$workspace_dir",
  "manifest_path": "$canon_manifest",
  "baseline": "$baseline",
  "owned_paths": [$owned_json],
  "frozen_paths": [$frozen_json],
  "status": "exported",
  "patch_file": "$canon_patch",
  "patch_digest": "$patch_digest",
  "touched_paths": [$touched_json],
  "exported_at": "$exported_at"
}
EOF

  printf '%s\n' "$canon_patch"
}

# ---------------------------------------------------------------------------
# Command: integrate
# ---------------------------------------------------------------------------
cmd_integrate() {
  local manifest_path=""
  local target_repo=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --manifest)
        [ $# -ge 2 ] || fail "--manifest requires a path"
        manifest_path="$2"
        shift 2
        ;;
      --manifest=*)
        manifest_path="${1#*=}"
        shift
        ;;
      --target-repo)
        [ $# -ge 2 ] || fail "--target-repo requires a path"
        target_repo="$2"
        shift 2
        ;;
      --target-repo=*)
        target_repo="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unrecognized argument for integrate: $1"
        ;;
    esac
  done

  [ -n "$manifest_path" ] || fail "--manifest is required"
  local canon_manifest
  canon_manifest="$(canonicalize_path "$manifest_path")"
  [ -f "$canon_manifest" ] || fail "manifest file does not exist: $manifest_path"

  local marker
  marker="$(json_extract_string "$canon_manifest" "marker")"
  [ "$marker" = "$MANIFEST_MARKER" ] || fail "invalid manifest marker in $manifest_path"

  local status patch_file patch_digest source_repo task_id
  status="$(json_extract_string "$canon_manifest" "status")"
  patch_file="$(json_extract_string "$canon_manifest" "patch_file")"
  patch_digest="$(json_extract_string "$canon_manifest" "patch_digest")"
  source_repo="$(json_extract_string "$canon_manifest" "source_repo")"
  task_id="$(json_extract_string "$canon_manifest" "task_id")"

  [ -n "$patch_file" ] || fail "manifest does not record an exported patch file; run verify-export first"
  [ -n "$patch_digest" ] || fail "manifest does not record a patch digest; run verify-export first"
  [ -f "$patch_file" ] || fail "patch file not found at: $patch_file"

  # 1. Content digest verification
  local actual_hex
  actual_hex="$(compute_sha256 "$patch_file")"
  local actual_digest="sha256:$actual_hex"
  if [ "$actual_digest" != "$patch_digest" ]; then
    fail "patch content digest mismatch: expected $patch_digest, got $actual_digest"
  fi

  # Determine target repository
  if [ -z "$target_repo" ]; then
    target_repo="$source_repo"
  fi
  local canon_target
  canon_target="$(canonicalize_path "$target_repo")"
  [ -d "$canon_target" ] || fail "target repository directory does not exist: $target_repo"
  if ! git -C "$canon_target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "target repository is not a git worktree: $target_repo"
  fi

  # 2. Preflight into disposable integration checkout
  local tmp_integ_base="${TMPDIR:-/tmp}/offload-integ-$task_id-XXXXXX"
  local integ_dir
  integ_dir="$(mktemp -d "$tmp_integ_base")/checkout"
  mkdir -p "$(dirname "$integ_dir")"

  # Create disposable detached worktree at target repo's current HEAD
  if ! git -C "$canon_target" worktree add --detach "$integ_dir" HEAD >/dev/null 2>&1; then
    fail "failed to create disposable integration worktree at $integ_dir"
  fi

  local preflight_passed=false
  local apply_err_file
  apply_err_file="$(mktemp "${TMPDIR:-/tmp}/integ-err.XXXXXX")"

  # Test application in the disposable checkout
  if git -C "$integ_dir" apply --binary "$patch_file" 2>"$apply_err_file"; then
    preflight_passed=true
  fi

  # Clean up disposable integration checkout unconditionally
  git -C "$canon_target" worktree remove --force "$integ_dir" >/dev/null 2>&1 || true
  rm -rf "$(dirname "$integ_dir")"
  git -C "$canon_target" worktree prune >/dev/null 2>&1 || true

  if ! $preflight_passed; then
    local apply_err=""
    if [ -f "$apply_err_file" ]; then
      apply_err="$(cat "$apply_err_file")"
      rm -f "$apply_err_file"
    fi
    fail "integration preflight failed (patch conflict or unapplicable delta); candidate retained without publishing changes to target checkout: ${apply_err}"
  fi
  rm -f "$apply_err_file"

  # 3. Preflight succeeded: apply patch directly to target repository
  if ! git -C "$canon_target" apply --binary "$patch_file"; then
    fail "failed to apply patch to target repository: $target_repo"
  fi

  # 4. Update manifest status to integrated
  local integrated_at
  integrated_at="$(get_iso_timestamp)"

  if command -v jq >/dev/null 2>&1; then
    local tmp_m
    tmp_m="$(mktemp "${TMPDIR:-/tmp}/manifest-update.XXXXXX")"
    jq --arg st "integrated" --arg iat "$integrated_at" '.status = $st | .integrated_at = $iat' "$canon_manifest" > "$tmp_m"
    mv "$tmp_m" "$canon_manifest"
  else
    # Simple sed replacement of status line
    sed -i.bak -e 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "integrated"/' "$canon_manifest"
    rm -f "$canon_manifest.bak"
  fi

  printf 'Successfully integrated candidate %s into %s\n' "$task_id" "$canon_target"
}

# ---------------------------------------------------------------------------
# Command: cleanup
# ---------------------------------------------------------------------------
cmd_cleanup() {
  local manifest_path=""
  local status="success"

  while [ $# -gt 0 ]; do
    case "$1" in
      --manifest)
        [ $# -ge 2 ] || fail "--manifest requires a path"
        manifest_path="$2"
        shift 2
        ;;
      --manifest=*)
        manifest_path="${1#*=}"
        shift
        ;;
      --status)
        [ $# -ge 2 ] || fail "--status requires a value"
        status="$2"
        shift 2
        ;;
      --status=*)
        status="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unrecognized argument for cleanup: $1"
        ;;
    esac
  done

  [ -n "$manifest_path" ] || fail "--manifest is required"
  local canon_manifest
  canon_manifest="$(canonicalize_path "$manifest_path")"
  [ -f "$canon_manifest" ] || fail "manifest file does not exist: $manifest_path"

  local marker
  marker="$(json_extract_string "$canon_manifest" "marker")"
  [ "$marker" = "$MANIFEST_MARKER" ] || fail "invalid manifest marker in $manifest_path"

  local workspace_dir source_repo task_id patch_file
  workspace_dir="$(json_extract_string "$canon_manifest" "workspace_dir")"
  source_repo="$(json_extract_string "$canon_manifest" "source_repo")"
  task_id="$(json_extract_string "$canon_manifest" "task_id")"
  patch_file="$(json_extract_string "$canon_manifest" "patch_file")"

  [ -n "$workspace_dir" ] || fail "manifest does not specify workspace_dir"
  [ -n "$source_repo" ] || fail "manifest does not specify source_repo"

  case "$status" in
    success)
      ;;
    failed|retain)
      printf 'Candidate %s marked %s; retaining workspace at %s\n' "$task_id" "$status" "$workspace_dir"
      exit 0
      ;;
    *)
      fail "invalid cleanup status: $status (must be success, failed, or retain)"
      ;;
  esac

  # If workspace directory is already gone, prune and remove manifest
  if [ ! -d "$workspace_dir" ]; then
    git -C "$source_repo" worktree prune >/dev/null 2>&1 || true
    rm -f "$canon_manifest"
    [ -n "$patch_file" ] && rm -f "$patch_file"
    printf 'Cleaned up manifest for absent workspace: %s\n' "$workspace_dir"
    exit 0
  fi

  local canon_workspace
  canon_workspace="$(canonicalize_path "$workspace_dir")"
  local canon_source
  canon_source="$(canonicalize_path "$source_repo")"

  # Safety Guards:
  # 1. Reject filesystem root
  if [ "$canon_workspace" = "/" ] || [[ "$canon_workspace" =~ ^[a-zA-Z]:[/\\]?$ ]]; then
    fail "refusing to clean filesystem root: $canon_workspace"
  fi

  # 2. Reject process current directory
  local cwd_phys
  cwd_phys="$(pwd -P)"
  if [ "$canon_workspace" = "$cwd_phys" ]; then
    fail "refusing to clean process current directory: $canon_workspace"
  fi

  # 3. Reject home directory
  if [ -n "${HOME:-}" ] && [ "$canon_workspace" = "$(canonicalize_path "$HOME")" ]; then
    fail "refusing to clean user home directory: $canon_workspace"
  fi
  if [ -n "${USERPROFILE:-}" ] && [ "$canon_workspace" = "$(canonicalize_path "$USERPROFILE")" ]; then
    fail "refusing to clean user profile directory: $canon_workspace"
  fi

  # 4. Reject source repository or any top-level git repository
  if [ "$canon_workspace" = "$canon_source" ]; then
    fail "refusing to clean source repository checkout: $canon_workspace"
  fi
  if [ -d "$canon_workspace/.git" ]; then
    fail "refusing to clean main git repository (not a detached worktree): $canon_workspace"
  fi

  # 5. Marker check: must contain .offload-execution-workspace
  local marker_file="$canon_workspace/$MARKER_NAME"
  if [ ! -f "$marker_file" ]; then
    fail "refusing to clean unmarked directory (missing $MARKER_NAME): $canon_workspace"
  fi
  local marker_val
  marker_val="$(tr -d '\r\n' < "$marker_file")"
  if [ "$marker_val" != "$MARKER_CONTENT" ]; then
    fail "refusing to clean directory with invalid marker content: $canon_workspace"
  fi

  # 6. Must be a registered worktree of source_repo
  local is_registered=false
  while IFS= read -r wt_line; do
    wt_line="${wt_line%$'\r'}"
    case "$wt_line" in
      worktree\ *)
        local wt_path="${wt_line#worktree }"
        if [ "$(canonicalize_path "$wt_path")" = "$canon_workspace" ]; then
          is_registered=true
          break
        fi
        ;;
    esac
  done < <(git -C "$canon_source" worktree list --porcelain 2>/dev/null || true)

  if ! $is_registered; then
    fail "directory is not registered as a worktree of $source_repo: $canon_workspace"
  fi

  # Safe to remove
  git -C "$canon_source" worktree remove --force "$canon_workspace" >/dev/null 2>&1 || true
  if [ -d "$canon_workspace" ]; then
    rm -rf "$canon_workspace"
  fi
  git -C "$canon_source" worktree prune >/dev/null 2>&1 || true

  # Also remove parent scratch directory if created specifically for this task
  local ws_parent
  ws_parent="$(dirname "$canon_workspace")"
  if [[ "$(basename "$ws_parent")" == offload-exec-* ]]; then
    rm -rf "$ws_parent"
  fi

  # Remove manifest and patch artifact
  rm -f "$canon_manifest"
  [ -n "$patch_file" ] && rm -f "$patch_file"

  printf 'Cleaned up execution workspace: %s\n' "$canon_workspace"
}

# ---------------------------------------------------------------------------
# CLI Entrypoint
# ---------------------------------------------------------------------------
[ $# -gt 0 ] || { usage; exit 1; }

command_verb="$1"
shift

case "$command_verb" in
  create)
    cmd_create "$@"
    ;;
  verify-export|export)
    cmd_verify_export "$@"
    ;;
  integrate)
    cmd_integrate "$@"
    ;;
  cleanup)
    cmd_cleanup "$@"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    fail "unrecognized command: $command_verb (must be create, verify-export, integrate, or cleanup)"
    ;;
esac
