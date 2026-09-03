#!/usr/bin/env bash
# tests/test_review_artifact.sh
# Verifies that verify-export records one complete, digest-checked review artifact.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/scripts/execution-workspace.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/offload-test-review-artifact.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Test User'
  git -C "$repo" config user.email 'test@example.com'
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config core.autocrlf false
}

REPO="$TMP_ROOT/repo"
SCRATCH="$TMP_ROOT/scratch"
init_repo "$REPO"
mkdir -p "$SCRATCH"
printf 'committed baseline\n' > "$REPO/committed.txt"
printf 'staged baseline\n' > "$REPO/staged.txt"
printf 'unstaged baseline\n' > "$REPO/unstaged.txt"
printf 'deleted baseline\n' > "$REPO/deleted.txt"
printf 'rename source baseline\n' > "$REPO/renamed.txt"
printf '\000\001\002\003' > "$REPO/binary.dat"
git -C "$REPO" add .
git -C "$REPO" commit -q -m baseline
BASELINE=$(git -C "$REPO" rev-parse HEAD | tr -d '\r\n')

MANIFEST="$SCRATCH/candidate.manifest.json"
WORKSPACE=$(
  "$HELPER" create --source-repo "$REPO" --task-id candidate --baseline "$BASELINE" \
    --owned committed.txt --owned staged.txt --owned unstaged.txt --owned deleted.txt \
    --owned renamed.txt --owned binary.dat --owned new.txt \
    --manifest "$MANIFEST"
)
pass 'candidate workspace is created'

printf 'committed edit\n' > "$WORKSPACE/committed.txt"
git -C "$WORKSPACE" add committed.txt
git -C "$WORKSPACE" commit -q -m committed-edit
printf 'staged edit\n' > "$WORKSPACE/staged.txt"
git -C "$WORKSPACE" add staged.txt
printf 'unstaged edit\n' > "$WORKSPACE/unstaged.txt"
printf 'new file edit\n' > "$WORKSPACE/new.txt"
rm "$WORKSPACE/deleted.txt"
git -C "$WORKSPACE" mv renamed.txt renamed-final.txt
printf '\000\011\010\007' > "$WORKSPACE/binary.dat"

if "$HELPER" verify-export --manifest "$MANIFEST" >/dev/null 2>&1; then
  fail 'export accepted an unowned rename destination'
fi
pass 'export rejects an unowned rename destination'

jq '.owned_paths += ["renamed-final.txt"]' "$MANIFEST" > "$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"

ARTIFACT=$("$HELPER" verify-export --manifest "$MANIFEST")
[ -f "$ARTIFACT" ] || fail 'review artifact was not written'
pass 'mixed candidate changes export successfully'

grep -Fq 'committed edit' "$ARTIFACT" || fail 'artifact missing committed edit'
pass 'artifact contains committed edits'
grep -Fq 'staged edit' "$ARTIFACT" || fail 'artifact missing staged edit'
pass 'artifact contains staged edits'
grep -Fq 'unstaged edit' "$ARTIFACT" || fail 'artifact missing unstaged edit'
pass 'artifact contains unstaged edits'
grep -Fq 'new file edit' "$ARTIFACT" || fail 'artifact missing new file'
pass 'artifact contains new files'
grep -Fq 'deleted file mode' "$ARTIFACT" || fail 'artifact missing deletion metadata'
pass 'artifact contains deletions'
grep -Fq 'rename from renamed.txt' "$ARTIFACT" || fail 'artifact missing rename source'
grep -Fq 'rename to renamed-final.txt' "$ARTIFACT" || fail 'artifact missing rename destination'
pass 'artifact contains rename metadata'
grep -Fq 'GIT binary patch' "$ARTIFACT" || fail 'artifact missing binary patch'
pass 'artifact identifies binary changes'

RECORDED_DIGEST=$(sed -n 's/.*"patch_digest": "\([^"]*\)".*/\1/p' "$MANIFEST")
ACTUAL_DIGEST="sha256:$(sha256sum "$ARTIFACT" | awk '{print tolower($1)}')"
[ "$RECORDED_DIGEST" = "$ACTUAL_DIGEST" ] || fail 'manifest digest does not match artifact bytes'
pass 'manifest records the artifact digest'

if "$HELPER" verify-export --manifest "$MANIFEST" --patch-output "$WORKSPACE/review.patch" >/dev/null 2>&1; then
  fail 'export accepted an artifact path inside the candidate'
fi
pass 'export rejects an artifact path inside the candidate'

BEFORE=$(sha256sum "$ARTIFACT" | awk '{print $1}')
printf 'candidate changed after export\n' > "$WORKSPACE/unstaged.txt"
AFTER=$(sha256sum "$ARTIFACT" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] || fail 'candidate mutation changed recorded artifact'
pass 'candidate changes do not mutate the recorded artifact'

# Fake reviewer consumes the recorded artifact, never the candidate checkout.
grep -Fq 'staged edit' "$ARTIFACT" || fail 'fake reviewer could not quote artifact'
pass 'fake reviewer can quote the recorded artifact'
[ "sha256:$(sha256sum "$ARTIFACT" | awk '{print tolower($1)}')" = "$RECORDED_DIGEST" ] || fail 'digest recheck failed'
pass 'quote verification can recheck the recorded digest'

printf 'all review artifact shell tests passed\n'
