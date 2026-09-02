<!-- offload-review-remediation:09 -->

Blocked by: #3

Priority: P2. Review findings: F-07. Remediation ticket 09 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

## Problem

The PowerShell launcher starts AGY before opening output streams. If stream creation fails, the child escapes cleanup and continues running after the launcher exits.

## Deliverable

Validate destinations and open owned resources before starting the child. Put every post-start operation under a cleanup path that terminates and waits for the child on launcher failure and disposes streams.

## Acceptance criteria

- [ ] Identical output/error paths fail before a fake worker starts.
- [ ] Locked or invalid output destinations fail without starting a worker.
- [ ] A controlled exception after launch causes the child to stop before the launcher returns; no completion marker appears afterward.
- [ ] Streams are disposed on success, launch failure, and post-launch failure, so the output files can be reopened.
- [ ] Successful launch output, error capture, process metadata, exit codes, and explicit quota handoff behavior remain consistent with their existing contracts.

## Source evidence

- [scripts/run-agy-json.ps1:408](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/run-agy-json.ps1#L408)
- [scripts/run-agy-json.ps1:413](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/run-agy-json.ps1#L413)

## Implementation pointers

- [scripts/run-agy-json.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/run-agy-json.ps1)
- [tests/test_model_routing.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_model_routing.ps1)

New helper or test filenames under listed directories are implementation choices.

## Verification

Use the now-executed PowerShell suite and disposable fake workers that write delayed markers. Do not consume live AGY quota.

## Scope and constraints

The blocker establishes that routing test groups actually execute. If new cases belong in a separate focused suite, keep that suite explicitly invoked.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
