---
id: offload-review-05
status: published
priority: P1
labels: [bug, review-remediation]
findings: [F-02, F-03]
blocked_by: [offload-review-03, offload-review-04]
---

# 05. Run execution stages through isolated workspaces and retire shared-tree dispatch

Blocked by: [03](./03-verify-baseline-relative-scope.md), [04](./04-add-isolated-execution-workspaces.md)

Source: [whole-skill audit](../evidence/review.md), F-02, F-03. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#7](https://github.com/anthonyandrei/offload/issues/7). GitHub is the active issue tracker.

## Problem

Adding baseline and workspace helpers does not fix the existing instructions. Gate authors still write before an untouched baseline is established, and implementers still share the caller's tree.

## Deliverable

Migrate gate-author and implementer dispatch to ticket 04's lifecycle. Verify gate authors against the original baseline before importing approved tests into an integration checkout. Freeze that gate baseline before creating implementer worktrees. Retire no-baseline scope calls and shared-tree writing examples.

## Acceptance criteria

- [ ] The documented Bash and PowerShell machine-gated flow completes with two disjoint fake implementers and imports both verified changes without sibling scope failures.
- [ ] A gate author that commits an unowned source edit is rejected before its output can become the implementation baseline.
- [ ] Implementers receive the approved frozen gates and an externally recorded baseline; committed gate edits are rejected.
- [ ] Overlapping assignments run serially from the newly accepted baseline, and all accepted deltas undergo scope and gate verification before publication to the caller.
- [ ] Retries retain the original verification baseline for that writing stage; a failed attempt never becomes an implicitly trusted baseline.
- [ ] Quota handoff records still-running candidates and artifacts immediately without waiting for sibling completion; normal cleanup waits for workers to stop.
- [ ] All execution-mode examples supply a baseline and isolated working directory, and the scope helpers reject omitted baselines after migration.
- [ ] A final combined gate check runs before publishing the integrated result; conflicts or failed gates leave the caller's existing work intact.

## Implementation pointers

- [modes/execution.md](../../../modes/execution.md)
- [SKILL.md](../../../SKILL.md)
- [README.md](../../../README.md)
- [AGENTS.md](../../../AGENTS.md)
- [CLAUDE.md](../../../CLAUDE.md)
- [CONTEXT.md](../../../CONTEXT.md)
- [scripts/check-execution-scope.ps1](../../../scripts/check-execution-scope.ps1)
- [scripts/check-execution-scope.sh](../../../scripts/check-execution-scope.sh)
- [tests/test_workflow_static.ps1](../../../tests/test_workflow_static.ps1)
- [tests/](../../../tests/)

Evidence locations at the reviewed revision: `modes/execution.md:90`, `modes/execution.md:132`, `modes/execution.md:136`, `modes/execution.md:178`. New helper or test filenames under listed directories are implementation choices.

## Verification

Run executable workflow cases with fake AGY workers for both shell families, the scope suites, and relevant static checks. Inspect current architecture pointers for agreement with the migrated mode.

## Scope and constraints

This ticket is the migrate and contract stage for one execution mode. Use the helpers from ticket 04 rather than adding another orchestration framework. Diff-review completeness and acceptance remain tickets 06 and 07.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

