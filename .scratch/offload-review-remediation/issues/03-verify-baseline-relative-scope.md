---
id: offload-review-03
status: published
priority: P1
labels: [bug, review-remediation, ready-for-agent]
findings: [F-03, F-06]
blocked_by: []
---

# 03. Check committed and working-tree edits against a fixed baseline

Blocked by: None

Source: [whole-skill audit](../evidence/review.md), F-03, F-06. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#5](https://github.com/anthonyandrei/offload/issues/5). GitHub is the active issue tracker.

## Problem

The scope helpers trust git status. A worker can commit a frozen or unowned edit and pass with a clean status. Bash also returns success when the git status command in process substitution fails.

## Deliverable

Expand the paired helper contract with an explicit immutable baseline revision. Compute the complete final delta against that revision and compare frozen contents with the baseline. Preserve the old call form only until ticket 05 migrates callers.

## Acceptance criteria

- [ ] A committed unowned edit and a committed frozen edit both produce nonzero results even when git status is clean.
- [ ] Owned-only committed, staged, unstaged, and new-file changes pass; unowned or frozen changes in each applicable state fail.
- [ ] Renames and deletions check all affected paths, with existing path normalization and NUL-safe filename handling preserved.
- [ ] Missing or invalid supplied baselines fail; the helper never silently substitutes current HEAD for a supplied baseline.
- [ ] A mocked git status failure with exit 73, and failures of any other Git query used for verification, produce nonzero helper results.
- [ ] Both shell families expose equivalent baseline semantics and diagnostics.

## Implementation pointers

- [scripts/check-execution-scope.ps1](../../../scripts/check-execution-scope.ps1)
- [scripts/check-execution-scope.sh](../../../scripts/check-execution-scope.sh)
- [tests/test_execution_scope.ps1](../../../tests/test_execution_scope.ps1)
- [tests/test_execution_scope.sh](../../../tests/test_execution_scope.sh)

Evidence locations at the reviewed revision: `scripts/check-execution-scope.ps1:145`, `scripts/check-execution-scope.sh:138`. New helper or test filenames under listed directories are implementation choices.

## Verification

Extend and run both execution-scope suites with temporary Git repositories and controlled Git failure mocks. Check final content relative to the captured baseline, not a worker-reported revision.

## Scope and constraints

This is the expand stage. Temporary compatibility is not sufficient to close F-03; ticket 05 must require the baseline in every execution workflow. Worktrees and baseline checks are not an OS write sandbox.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

