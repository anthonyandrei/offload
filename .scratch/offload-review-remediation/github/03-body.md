<!-- offload-review-remediation:03 -->

Blocked by: None

Priority: P1. Review findings: F-03, F-06. Remediation ticket 03 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

## Problem

The scope helpers trust git status. A worker can commit a frozen or unowned edit and pass with a clean status. Bash also returns success when the git status command in process substitution fails.

## Deliverable

Expand the paired helper contract with an explicit immutable baseline revision. Compute the complete final delta against that revision and compare frozen contents with the baseline. Preserve the old call form only until #7 migrates callers.

## Acceptance criteria

- [ ] A committed unowned edit and a committed frozen edit both produce nonzero results even when git status is clean.
- [ ] Owned-only committed, staged, unstaged, and new-file changes pass; unowned or frozen changes in each applicable state fail.
- [ ] Renames and deletions check all affected paths, with existing path normalization and NUL-safe filename handling preserved.
- [ ] Missing or invalid supplied baselines fail; the helper never silently substitutes current HEAD for a supplied baseline.
- [ ] A mocked git status failure with exit 73, and failures of any other Git query used for verification, produce nonzero helper results.
- [ ] Both shell families expose equivalent baseline semantics and diagnostics.

## Source evidence

- [scripts/check-execution-scope.ps1:145](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/check-execution-scope.ps1#L145)
- [scripts/check-execution-scope.sh:138](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/check-execution-scope.sh#L138)

## Implementation pointers

- [scripts/check-execution-scope.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/check-execution-scope.ps1)
- [scripts/check-execution-scope.sh](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/check-execution-scope.sh)
- [tests/test_execution_scope.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_execution_scope.ps1)
- [tests/test_execution_scope.sh](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_execution_scope.sh)

New helper or test filenames under listed directories are implementation choices.

## Verification

Extend and run both execution-scope suites with temporary Git repositories and controlled Git failure mocks. Check final content relative to the captured baseline, not a worker-reported revision.

## Scope and constraints

This is the expand stage. Temporary compatibility is not sufficient to close F-03; #7 must require the baseline in every execution workflow. Worktrees and baseline checks are not an OS write sandbox.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
