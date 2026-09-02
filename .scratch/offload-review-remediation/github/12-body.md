<!-- offload-review-remediation:12 -->

Blocked by: None

Priority: P2. Review findings: F-13. Remediation ticket 12 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

## Problem

Retry and revision examples reuse synthesizer.json and auditor.json. The launchers truncate those destinations, so attempt 1's routing record can point to attempt 2's output.

## Deliverable

Keep worker_id stable and use attempt-specific output, error, and process-artifact paths throughout dispatch/retry examples. Record an explicit accepted attempt for downstream stages.

## Acceptance criteria

- [ ] Initial and retry dispatch for the same worker use distinct artifact paths containing their attempt numbers.
- [ ] A fake second dispatch leaves the first output/error artifacts byte-for-byte intact.
- [ ] Both attempt records point to their own artifacts and retain the same worker_id.
- [ ] Downstream synthesis, audit, and report examples consume the explicitly selected attempt rather than whichever file was most recently overwritten.
- [ ] All three modes follow the convention, and maximum two attempts plus existing retry classification remain unchanged.

## Source evidence

- [modes/web-research.md:200](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md#L200)
- [modes/web-research.md:279](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md#L279)
- [modes/web-research.md:307](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md#L307)

## Implementation pointers

- [SKILL.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/SKILL.md)
- [modes/execution.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md)
- [modes/repo-research.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/repo-research.md)
- [modes/web-research.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md)
- [tests/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/)

New helper or test filenames under listed directories are implementation choices.

## Verification

Execute two fake attempts using each shell's documented naming convention, compare first-attempt hashes, and validate the resulting routing record. No launcher auto-renaming is required.

## Scope and constraints

This ticket changes orchestration filenames, not model selection or retry count. Coordinate edits to execution.md with #7, #8, #9 instead of applying concurrent edits to that file.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
