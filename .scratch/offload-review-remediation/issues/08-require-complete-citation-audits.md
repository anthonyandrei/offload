---
id: offload-review-08
status: published
priority: P1
labels: [bug, review-remediation, ready-for-agent]
findings: [F-05]
blocked_by: []
---

# 08. Require audit coverage for every claim and citation pair

Blocked by: None

Source: [whole-skill audit](../evidence/review.md), F-05. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#10](https://github.com/anthonyandrei/offload/issues/10). GitHub is the active issue tracker.

## Problem

The auditor schema accepts an empty citation_audits array with final_status pass. The workflow does not compare returned audits with the synthesis claim ledger.

## Deliverable

Derive the required claim_id and URL pairs from the ledger and validate exact audit coverage and verdict consistency before accepting the synthesis.

## Acceptance criteria

- [ ] A nonempty required pair set rejects empty or partial citation_audits even when final_status is pass.
- [ ] Duplicate and unknown claim/citation pairs are rejected; two citations for one claim require separate coverage.
- [ ] Every required pair has one supported verdict before automated acceptance, and failed or unresolved entries cannot coexist with an accepted overall pass.
- [ ] A ledger with no auditable pairs follows an explicit documented branch and cannot bypass citations required by the research assignment.
- [ ] Complete valid coverage passes in both shell workflows; invalid responses follow the existing bounded revision or orchestrator fallback path.

## Implementation pointers

- [modes/web-research.md](../../../modes/web-research.md)
- [scripts/](../../../scripts/)
- [tests/test_research_modes.sh](../../../tests/test_research_modes.sh)
- [tests/test_workflow_static.ps1](../../../tests/test_workflow_static.ps1)
- [tests/](../../../tests/)

Evidence locations at the reviewed revision: `modes/web-research.md:292`, `modes/web-research.md:306`. New helper or test filenames under listed directories are implementation choices.

## Verification

Run fixture-based audit acceptance tests for empty, partial, duplicate, unknown, contradictory, and complete results. Use synthetic ledger data and no live browsing.

## Scope and constraints

Do not change what constitutes a trustworthy source in this ticket. This fix checks coverage and internal consistency of the required audit.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

