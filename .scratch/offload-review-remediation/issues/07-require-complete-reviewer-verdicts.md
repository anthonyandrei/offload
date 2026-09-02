---
id: offload-review-07
status: published
priority: P1
labels: [bug, review-remediation]
findings: [F-05]
blocked_by: [offload-review-06]
---

# 07. Require one valid reviewer verdict for every requested criterion

Blocked by: [06](./06-review-complete-change-artifacts.md)

Source: [whole-skill audit](../evidence/review.md), F-05. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#9](https://github.com/anthonyandrei/offload/issues/9). GitHub is the active issue tracker.

## Problem

The reviewer schema accepts an empty criteria array, and the workflow accepts when all returned quotes match. Empty or partial responses can therefore pass without addressing the task.

## Deliverable

Assign stable IDs to requested criteria and add a mechanical coverage check in both shell workflows before accepting any reviewer response.

## Acceptance criteria

- [ ] Empty output is rejected when criteria were requested.
- [ ] Missing, duplicate, and unknown criterion IDs are rejected, even when every returned quote exists in the artifact.
- [ ] Each requested criterion has exactly one verdict; fail or hedge prevents automated acceptance.
- [ ] Every pass has a literal matching evidence line from ticket 06's artifact, with matching performed on data rather than interpolated shell code.
- [ ] A complete all-pass response with valid evidence is accepted, and malformed or incomplete responses route to direct orchestrator review.

## Implementation pointers

- [modes/execution.md](../../../modes/execution.md)
- [scripts/](../../../scripts/)
- [tests/](../../../tests/)

Evidence locations at the reviewed revision: `modes/execution.md:210`, `modes/execution.md:246`. New helper or test filenames under listed directories are implementation choices.

## Verification

Use fixed criterion sets and fake reviewer envelopes for empty, partial, duplicate, unknown, failed, hedged, forged-quote, and complete outputs. Exercise both documented shell flows.

## Scope and constraints

A minimum array length alone does not establish coverage. Preserve the existing direct-review fallback and bounded retry policy.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

