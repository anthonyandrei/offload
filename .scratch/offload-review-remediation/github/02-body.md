<!-- offload-review-remediation:02 -->

Blocked by: None

Priority: P1. Review findings: F-01. Remediation ticket 02 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

## Problem

The workspace and extraction helpers write to Console.Out, while the mode examples capture the PowerShell pipeline. Workspace.Trim() fails on null, and merged researcher evidence can silently become null.

## Deliverable

Make the helpers emit their result through the PowerShell pipeline and keep diagnostics on the error channel. Test the exact documented in-process assignments and native pwsh -File invocation.

## Acceptance criteria

- [ ] The documented workspace assignment returns one nonempty existing workspace path and .Trim() succeeds.
- [ ] The documented extraction assignment for two valid researcher envelopes returns nonempty JSON containing both findings.
- [ ] Both direct & invocation and native pwsh -File invocation return the same semantic payload without diagnostic text mixed into JSON.
- [ ] Invalid input still fails with the intended exit/error contract, and the mode examples match the tested commands.

## Source evidence

- [scripts/make-research-workspace.ps1:170](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/make-research-workspace.ps1#L170)
- [scripts/extract-structured-output.ps1:77](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/extract-structured-output.ps1#L77)
- [modes/repo-research.md:40](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/repo-research.md#L40)
- [modes/web-research.md:211](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md#L211)

## Implementation pointers

- [scripts/make-research-workspace.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/make-research-workspace.ps1)
- [scripts/extract-structured-output.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/extract-structured-output.ps1)
- [modes/repo-research.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/repo-research.md)
- [modes/web-research.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md)
- [tests/test_research_helpers.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_research_helpers.ps1)

New helper or test filenames under listed directories are implementation choices.

## Verification

Add workflow-shaped cases to tests/test_research_helpers.ps1 using disposable workspaces and fixture envelopes, then run that suite.

## Scope and constraints

Keep the Windows workflow native to PowerShell 7. Do not add Bash, jq, or Python dependencies.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
