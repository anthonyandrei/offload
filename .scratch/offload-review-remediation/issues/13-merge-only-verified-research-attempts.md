---
id: offload-review-13
status: published
priority: P2
labels: [bug, review-remediation]
findings: [F-12]
blocked_by: [offload-review-02, offload-review-12]
---

# 13. Continue synthesis from verified successful research angles

Blocked by: [02](./02-capture-powershell-research-output.md), [12](./12-preserve-per-attempt-artifacts.md)

Source: [whole-skill audit](../evidence/review.md), F-12. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#15](https://github.com/anthonyandrei/offload/issues/15). GitHub is the active issue tracker.

## Problem

The synthesis snippets glob every researcher JSON file. A failed envelope stops extraction even when two successful independent angles satisfy the documented partial-success policy.

## Deliverable

Build the extraction input list from the verified selected attempts, then check independent surviving research angles before synthesis. Retain failed and superseded files as diagnostics.

## Acceptance criteria

- [ ] Two verified successful independent angles plus one exhausted ERROR worker produce merged evidence from the two successful angles.
- [ ] A failed attempt followed by a verified retry contributes only the retry's findings.
- [ ] Completed but unverified results never enter synthesis.
- [ ] Two successful attempts for the same assignment do not count as two independent angles.
- [ ] Fewer than two surviving independent angles takes the documented fallback instead of dispatching synthesis.
- [ ] Both Bash and PowerShell snippets pass explicit selected file arrays and avoid globs that include failed or superseded envelopes.

## Implementation pointers

- [modes/web-research.md](../../../modes/web-research.md)
- [tests/test_research_helpers.ps1](../../../tests/test_research_helpers.ps1)
- [tests/test_research_modes.sh](../../../tests/test_research_modes.sh)

Evidence locations at the reviewed revision: `modes/web-research.md:197`, `modes/web-research.md:210`, `modes/web-research.md:316`. New helper or test filenames under listed directories are implementation choices.

## Verification

Run fake researcher fixtures through the actual extraction helper in each shell, including a successful PowerShell pipeline capture from ticket 02.

## Scope and constraints

Keep the existing independent-angle threshold and recovery policy. Do not silently drop failing files from provenance.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

