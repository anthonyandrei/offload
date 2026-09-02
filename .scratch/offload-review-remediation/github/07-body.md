<!-- offload-review-remediation:07 -->

Blocked by: #8

Priority: P1. Review findings: F-05. Remediation ticket 07 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

## Problem

The reviewer schema accepts an empty criteria array, and the workflow accepts when all returned quotes match. Empty or partial responses can therefore pass without addressing the task.

## Deliverable

Assign stable IDs to requested criteria and add a mechanical coverage check in both shell workflows before accepting any reviewer response.

## Acceptance criteria

- [ ] Empty output is rejected when criteria were requested.
- [ ] Missing, duplicate, and unknown criterion IDs are rejected, even when every returned quote exists in the artifact.
- [ ] Each requested criterion has exactly one verdict; fail or hedge prevents automated acceptance.
- [ ] Every pass has a literal matching evidence line from #8's artifact, with matching performed on data rather than interpolated shell code.
- [ ] A complete all-pass response with valid evidence is accepted, and malformed or incomplete responses route to direct orchestrator review.

## Source evidence

- [modes/execution.md:210](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L210)
- [modes/execution.md:246](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L246)

## Implementation pointers

- [modes/execution.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md)
- [scripts/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/)
- [tests/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/)

New helper or test filenames under listed directories are implementation choices.

## Verification

Use fixed criterion sets and fake reviewer envelopes for empty, partial, duplicate, unknown, failed, hedged, forged-quote, and complete outputs. Exercise both documented shell flows.

## Scope and constraints

A minimum array length alone does not establish coverage. Preserve the existing direct-review fallback and bounded retry policy.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
