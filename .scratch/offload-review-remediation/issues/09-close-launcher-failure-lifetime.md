---
id: offload-review-09
status: published
priority: P2
labels: [bug, review-remediation]
findings: [F-07]
blocked_by: [offload-review-01]
---

# 09. Prevent orphaned workers when PowerShell output setup fails

Blocked by: [01](./01-execute-model-routing-tests.md)

Source: [whole-skill audit](../evidence/review.md), F-07. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#11](https://github.com/anthonyandrei/offload/issues/11). GitHub is the active issue tracker.

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

## Implementation pointers

- [scripts/run-agy-json.ps1](../../../scripts/run-agy-json.ps1)
- [tests/test_model_routing.ps1](../../../tests/test_model_routing.ps1)

Evidence locations at the reviewed revision: `scripts/run-agy-json.ps1:408`, `scripts/run-agy-json.ps1:413`. New helper or test filenames under listed directories are implementation choices.

## Verification

Use the now-executed PowerShell suite and disposable fake workers that write delayed markers. Do not consume live AGY quota.

## Scope and constraints

The blocker establishes that routing test groups actually execute. If new cases belong in a separate focused suite, keep that suite explicitly invoked.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

