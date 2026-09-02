---
id: offload-review-04
status: published
priority: P1
labels: [bug, review-remediation]
findings: [F-02]
blocked_by: [offload-review-03]
---

# 04. Add a verified lifecycle for isolated execution worktrees

Blocked by: [03](./03-verify-baseline-relative-scope.md)

Source: [whole-skill audit](../evidence/review.md), F-02. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#6](https://github.com/anthonyandrei/offload/issues/6). GitHub is the active issue tracker.

## Problem

Per-worker ownership cannot be checked reliably while multiple writers share one working tree. The execution workflow needs a small, tested mechanism for creating isolated candidates and importing only their verified changes.

## Deliverable

Add paired shell-native execution-workspace helpers with a narrow create, verify/export, integrate, and cleanup contract. Store an orchestrator-owned manifest outside the worker checkout with task identity, absolute paths, baseline revision, and owned/frozen paths. Keep this beside the current workflow until ticket 05.

## Acceptance criteria

- [ ] Two workers starting from the same baseline can independently edit a.txt and b.txt, and each scope check passes against only its own candidate.
- [ ] An unowned or frozen change in either candidate blocks export/integration, including when the worker has committed it.
- [ ] Export captures committed and uncommitted final changes and records a content digest; integration consumes only that verified artifact.
- [ ] Integration into a disposable integration checkout preflights the whole change, detects conflicts, and retains candidates on failure without partially publishing changes to the caller checkout.
- [ ] Creation and cleanup only operate on manifest-owned paths; no existing caller checkout or unrelated worktree is reset, cleaned, or removed.
- [ ] The paired helpers pass equivalent disposable-repository cases and add no Windows dependency beyond PowerShell 7 and Git.

## Implementation pointers

- [scripts/](../../../scripts/)
- [tests/](../../../tests/)
- [docs/adr/](../../../docs/adr/)

Evidence locations at the reviewed revision: `modes/execution.md:136`, `modes/execution.md:178`. New helper or test filenames under listed directories are implementation choices.

## Verification

Add focused lifecycle suites for both shells using fake workers. Exercise two sibling tasks, a scope violation, an integration conflict, and cleanup ownership guards.

## Scope and constraints

This is an additive workspace capability. Keep its interface small enough for ticket 05 to use directly. Do not build a general scheduler or change the model policy. Record the worktree decision in a short ADR.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

