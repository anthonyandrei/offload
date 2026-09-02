<!-- offload-review-remediation:04 -->

Blocked by: #5

Priority: P1. Review findings: F-02. Remediation ticket 04 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

## Problem

Per-worker ownership cannot be checked reliably while multiple writers share one working tree. The execution workflow needs a small, tested mechanism for creating isolated candidates and importing only their verified changes.

## Deliverable

Add paired shell-native execution-workspace helpers with a narrow create, verify/export, integrate, and cleanup contract. Store an orchestrator-owned manifest outside the worker checkout with task identity, absolute paths, baseline revision, and owned/frozen paths. Keep this beside the current workflow until #7.

## Acceptance criteria

- [ ] Two workers starting from the same baseline can independently edit a.txt and b.txt, and each scope check passes against only its own candidate.
- [ ] An unowned or frozen change in either candidate blocks export/integration, including when the worker has committed it.
- [ ] Export captures committed and uncommitted final changes and records a content digest; integration consumes only that verified artifact.
- [ ] Integration into a disposable integration checkout preflights the whole change, detects conflicts, and retains candidates on failure without partially publishing changes to the caller checkout.
- [ ] Creation and cleanup only operate on manifest-owned paths; no existing caller checkout or unrelated worktree is reset, cleaned, or removed.
- [ ] The paired helpers pass equivalent disposable-repository cases and add no Windows dependency beyond PowerShell 7 and Git.

## Source evidence

- [modes/execution.md:136](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L136)
- [modes/execution.md:178](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L178)

## Implementation pointers

- [scripts/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/)
- [tests/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/)
- [docs/adr/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/docs/adr/)

New helper or test filenames under listed directories are implementation choices.

## Verification

Add focused lifecycle suites for both shells using fake workers. Exercise two sibling tasks, a scope violation, an integration conflict, and cleanup ownership guards.

## Scope and constraints

This is an additive workspace capability. Keep its interface small enough for #7 to use directly. Do not build a general scheduler or change the model policy. Record the worktree decision in a short ADR.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
