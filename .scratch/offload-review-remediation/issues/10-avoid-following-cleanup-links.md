---
id: offload-review-10
status: published
priority: P2
labels: [bug, review-remediation, ready-for-agent]
findings: [F-08]
blocked_by: []
---

# 10. Keep PowerShell cleanup inside the marked workspace

Blocked by: None

Source: [whole-skill audit](../evidence/review.md), F-08. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#12](https://github.com/anthonyandrei/offload/issues/12). GitHub is the active issue tracker.

## Problem

Cleanup checks top-level links but recursively enumerates files under ordinary directories. A nested junction lets attribute changes reach a sibling directory outside the workspace.

## Deliverable

Traverse entries without following reparse points at any depth. Remove the link itself, and only clear file attributes within the verified workspace traversal.

## Acceptance criteria

- [ ] A nested junction to a controlled sibling fixture is removed without changing the target's file content, existence, or read-only attributes.
- [ ] Ordinary read-only workspace files are removed on success, and retained report/provenance files remain intact.
- [ ] Top-level and nested links use the same no-follow rule.
- [ ] Marker validation, Git-root rejection, and other protected-path checks still fail safely.
- [ ] Tests resolve and verify every destructive fixture path inside a dedicated temporary test root before cleanup; no external or user-owned directory is used.

## Implementation pointers

- [scripts/cleanup-research-workspace.ps1](../../../scripts/cleanup-research-workspace.ps1)
- [tests/test_research_helpers.ps1](../../../tests/test_research_helpers.ps1)

Evidence locations at the reviewed revision: `scripts/cleanup-research-workspace.ps1:122`. New helper or test filenames under listed directories are implementation choices.

## Verification

Add and run controlled junction fixtures in tests/test_research_helpers.ps1 on Windows. Use existing-target links for the confirmed reproduction; record platform limitations rather than inventing unsupported coverage.

## Scope and constraints

The separate dangling-link allegation was not verified in the audit and is not a required reproduction. Preserve failure retention behavior.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

