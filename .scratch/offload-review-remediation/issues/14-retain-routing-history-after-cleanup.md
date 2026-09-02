---
id: offload-review-14
status: published
priority: P2
labels: [bug, review-remediation]
findings: [F-10]
blocked_by: [offload-review-10, offload-review-11, offload-review-12]
---

# 14. Preserve routing history and explain pruned evidence after success

Blocked by: [10](./10-avoid-following-cleanup-links.md), [11](./11-align-routing-provenance-examples.md), [12](./12-preserve-per-attempt-artifacts.md)

Source: [whole-skill audit](../evidence/review.md), F-10. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#16](https://github.com/anthonyandrei/offload/issues/16). GitHub is the active issue tracker.

## Problem

Success cleanup deletes routing-outcomes.json despite the shared requirement to maintain it. Optional web provenance embedding does not protect repository-research runs or explain deleted evidence paths.

## Deliverable

Preserve routing-outcomes.json on success. Before deleting raw artifacts, write and retain an evidence disposition manifest with each referenced relative path, existence before cleanup, content hash for existing regular files, and retained or pruned status. Keep raw-file pruning as the default success policy.

## Acceptance criteria

- [ ] Success cleanup preserves final.md, provenance.json when present, the workspace marker, routing-outcomes.json, and the evidence disposition manifest.
- [ ] Both attempts and their verification verdicts remain readable after cleanup in repository and web research fixtures.
- [ ] Every evidence path in the retained routing record has a disposition entry; missing inputs are explicitly marked missing instead of reported as pruned or verified.
- [ ] Evidence paths cannot authorize reads, hashing, attribute changes, or deletion outside the workspace or through a reparse point; external/link paths receive an explicit uninspected entry.
- [ ] An invalid routing record or failure to write the disposition manifest stops success cleanup before raw artifacts are removed.
- [ ] Failure/interruption retention remains unchanged, and repeating successful cleanup preserves the original manifest information rather than reclassifying pruned files as missing.
- [ ] Both shell families produce the same retention and disposition behavior.

## Implementation pointers

- [scripts/cleanup-research-workspace.ps1](../../../scripts/cleanup-research-workspace.ps1)
- [scripts/cleanup-research-workspace.sh](../../../scripts/cleanup-research-workspace.sh)
- [SKILL.md](../../../SKILL.md)
- [modes/repo-research.md](../../../modes/repo-research.md)
- [modes/web-research.md](../../../modes/web-research.md)
- [tests/test_research_helpers.ps1](../../../tests/test_research_helpers.ps1)
- [tests/test_research_modes.sh](../../../tests/test_research_modes.sh)

Evidence locations at the reviewed revision: `scripts/cleanup-research-workspace.ps1:111`, `scripts/cleanup-research-workspace.sh:130`, `SKILL.md:120`. New helper or test filenames under listed directories are implementation choices.

## Verification

Run paired cleanup fixtures containing successful and failed attempts, absent optional provenance, missing evidence, and an out-of-workspace evidence reference. Verify surviving records and disposal metadata after success and after a repeated cleanup.

## Scope and constraints

Use a separate disposition manifest so the routing schema need not change. It records provenance of cleanup, not a claim that pruned content remains available. Do not retain complete repository snapshots by default.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

