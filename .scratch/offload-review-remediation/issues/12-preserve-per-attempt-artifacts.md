---
id: offload-review-12
status: published
priority: P2
labels: [bug, review-remediation, ready-for-agent]
findings: [F-13]
blocked_by: []
---

# 12. Give every worker attempt distinct evidence paths

Blocked by: None

Source: [whole-skill audit](../evidence/review.md), F-13. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#14](https://github.com/anthonyandrei/offload/issues/14). GitHub is the active issue tracker.

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

## Implementation pointers

- [SKILL.md](../../../SKILL.md)
- [modes/execution.md](../../../modes/execution.md)
- [modes/repo-research.md](../../../modes/repo-research.md)
- [modes/web-research.md](../../../modes/web-research.md)
- [tests/](../../../tests/)

Evidence locations at the reviewed revision: `modes/web-research.md:200`, `modes/web-research.md:279`, `modes/web-research.md:307`. New helper or test filenames under listed directories are implementation choices.

## Verification

Execute two fake attempts using each shell's documented naming convention, compare first-attempt hashes, and validate the resulting routing record. No launcher auto-renaming is required.

## Scope and constraints

This ticket changes orchestration filenames, not model selection or retry count. Coordinate edits to execution.md with tickets 05 through 07 instead of applying concurrent edits to that file.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

