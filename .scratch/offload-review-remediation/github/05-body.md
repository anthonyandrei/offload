<!-- offload-review-remediation:05 -->

Blocked by: #5, #6

Priority: P1. Review findings: F-02, F-03. Remediation ticket 05 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

## Problem

Adding baseline and workspace helpers does not fix the existing instructions. Gate authors still write before an untouched baseline is established, and implementers still share the caller's tree.

## Deliverable

Migrate gate-author and implementer dispatch to #6's lifecycle. Verify gate authors against the original baseline before importing approved tests into an integration checkout. Freeze that gate baseline before creating implementer worktrees. Retire no-baseline scope calls and shared-tree writing examples.

## Acceptance criteria

- [ ] The documented Bash and PowerShell machine-gated flow completes with two disjoint fake implementers and imports both verified changes without sibling scope failures.
- [ ] A gate author that commits an unowned source edit is rejected before its output can become the implementation baseline.
- [ ] Implementers receive the approved frozen gates and an externally recorded baseline; committed gate edits are rejected.
- [ ] Overlapping assignments run serially from the newly accepted baseline, and all accepted deltas undergo scope and gate verification before publication to the caller.
- [ ] Retries retain the original verification baseline for that writing stage; a failed attempt never becomes an implicitly trusted baseline.
- [ ] Quota handoff records still-running candidates and artifacts immediately without waiting for sibling completion; normal cleanup waits for workers to stop.
- [ ] All execution-mode examples supply a baseline and isolated working directory, and the scope helpers reject omitted baselines after migration.
- [ ] A final combined gate check runs before publishing the integrated result; conflicts or failed gates leave the caller's existing work intact.

## Source evidence

- [modes/execution.md:90](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L90)
- [modes/execution.md:132](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L132)
- [modes/execution.md:136](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L136)
- [modes/execution.md:178](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md#L178)

## Implementation pointers

- [modes/execution.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/execution.md)
- [SKILL.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/SKILL.md)
- [README.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/README.md)
- [AGENTS.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/AGENTS.md)
- [CLAUDE.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/CLAUDE.md)
- [CONTEXT.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/CONTEXT.md)
- [scripts/check-execution-scope.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/check-execution-scope.ps1)
- [scripts/check-execution-scope.sh](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/check-execution-scope.sh)
- [tests/test_workflow_static.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_workflow_static.ps1)
- [tests/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/)

New helper or test filenames under listed directories are implementation choices.

## Verification

Run executable workflow cases with fake AGY workers for both shell families, the scope suites, and relevant static checks. Inspect current architecture pointers for agreement with the migrated mode.

## Scope and constraints

This ticket is the migrate and contract stage for one execution mode. Use the helpers from #6 rather than adding another orchestration framework. Diff-review completeness and acceptance remain #8, #9.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
