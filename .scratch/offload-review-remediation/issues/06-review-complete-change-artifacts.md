---
id: offload-review-06
status: published
priority: P1
labels: [bug, review-remediation]
findings: [F-04]
blocked_by: [offload-review-05]
---

# 06. Review one complete change artifact against the execution baseline

Blocked by: [05](./05-migrate-execution-to-isolated-workers.md)

Source: [whole-skill audit](../evidence/review.md), F-04. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#8](https://github.com/anthonyandrei/offload/issues/8). GitHub is the active issue tracker.

## Problem

Bare git diff omits staged changes and new files. Reviewers and quote matching can agree on an incomplete diff and still miss part of a task.

## Deliverable

Produce one immutable review artifact from each verified candidate and its recorded baseline, then pass the identical artifact to the reviewer and quote verifier. Reuse the delta export from ticket 04 where possible.

## Acceptance criteria

- [ ] A fixture containing a committed edit, staged edit, unstaged edit, and new file exposes every final change to review.
- [ ] Deletion and rename information is present, and binary changes are explicitly identified for direct review instead of silently omitted.
- [ ] The reviewer prompt reads the recorded artifact rather than running an independent bare git diff.
- [ ] Quote verification uses the exact artifact bytes or their verified digest; modifying the candidate after artifact creation cannot silently change the evidence being accepted.
- [ ] Git or artifact-generation failures prevent review acceptance, and both shells produce equivalent review coverage.

## Implementation pointers

- [modes/execution.md](../../../modes/execution.md)
- [scripts/](../../../scripts/)
- [tests/](../../../tests/)

Evidence locations at the reviewed revision: `modes/execution.md:216`, `modes/execution.md:232`, `modes/execution.md:242`. New helper or test filenames under listed directories are implementation choices.

## Verification

Add focused artifact-generation tests and execute the documented reviewer handoff with a fake reviewer. Compare the artifact's path/content coverage with the baseline delta.

## Scope and constraints

This ticket guarantees complete evidence. Ticket 07 adds exhaustive criterion coverage; do not treat successful quote lookup alone as sufficient acceptance.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

