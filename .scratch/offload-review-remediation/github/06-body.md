<!-- offload-review-remediation:06 -->

Blocked by: #7

Priority: P1. Review findings: F-04. Remediation ticket 06 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

## Problem

Bare git diff omits staged changes and new files. Reviewers and quote matching can agree on an incomplete diff and still miss part of a task.

## Deliverable

Produce one immutable review artifact from each verified candidate and its recorded baseline, then pass the identical artifact to the reviewer and quote verifier. Reuse the delta export from #6 where possible.

## Acceptance criteria

- [ ] A fixture containing a committed edit, staged edit, unstaged edit, and new file exposes every final change to review.
- [ ] Deletion and rename information is present, and binary changes are explicitly identified for direct review instead of silently omitted.
- [ ] The reviewer prompt reads the recorded artifact rather than running an independent bare git diff.
- [ ] Quote verification uses the exact artifact bytes or their verified digest; modifying the candidate after artifact creation cannot silently change the evidence being accepted.
- [ ] Git or artifact-generation failures prevent review acceptance, and both shells produce equivalent review coverage.

## Source evidence

- [modes/execution.md:216](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L216)
- [modes/execution.md:232](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L232)
- [modes/execution.md:242](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L242)

## Implementation pointers

- [modes/execution.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md)
- [scripts/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/)
- [tests/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/)

New helper or test filenames under listed directories are implementation choices.

## Verification

Add focused artifact-generation tests and execute the documented reviewer handoff with a fake reviewer. Compare the artifact's path/content coverage with the baseline delta.

## Scope and constraints

This ticket guarantees complete evidence. #9 adds exhaustive criterion coverage; do not treat successful quote lookup alone as sufficient acceptance.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
