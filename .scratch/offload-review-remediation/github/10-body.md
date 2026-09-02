<!-- offload-review-remediation:10 -->

Blocked by: None

Priority: P2. Review findings: F-08. Remediation ticket 10 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

## Problem

Cleanup checks top-level links but recursively enumerates files under ordinary directories. A nested junction lets attribute changes reach a sibling directory outside the workspace.

## Deliverable

Traverse entries without following reparse points at any depth. Remove the link itself, and only clear file attributes within the verified workspace traversal.

## Acceptance criteria

- [ ] A nested junction to a controlled sibling fixture is removed without changing the target's file content, existence, or read-only attributes.
- [ ] Ordinary read-only workspace files are removed on success, and retained report/provenance files remain intact.
- [ ] Top-level and nested links use the same no-follow rule.
- [ ] Marker validation, Git-root rejection, and other protected-path checks still fail safely.
- [ ] Tests resolve and verify every destructive fixture path inside a dedicated temporary test root before cleanup; no external or user-owned directory is used.

## Source evidence

- [scripts/cleanup-research-workspace.ps1:122](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/cleanup-research-workspace.ps1#L122)

## Implementation pointers

- [scripts/cleanup-research-workspace.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/cleanup-research-workspace.ps1)
- [tests/test_research_helpers.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_research_helpers.ps1)

New helper or test filenames under listed directories are implementation choices.

## Verification

Add and run controlled junction fixtures in tests/test_research_helpers.ps1 on Windows. Use existing-target links for the confirmed reproduction; record platform limitations rather than inventing unsupported coverage.

## Scope and constraints

The separate dangling-link allegation was not verified in the audit and is not a required reproduction. Preserve failure retention behavior.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
