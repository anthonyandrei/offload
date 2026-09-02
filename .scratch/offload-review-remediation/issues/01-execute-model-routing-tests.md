---
id: offload-review-01
status: published
priority: P2
labels: [bug, review-remediation, ready-for-agent]
findings: [F-09]
blocked_by: []
---

# 01. Execute every PowerShell model-routing test group

Blocked by: None

Source: [whole-skill audit](../evidence/review.md), F-09. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#3](https://github.com/anthonyandrei/offload/issues/3). GitHub is the active issue tracker.

## Problem

Fifty bare script blocks in tests/test_model_routing.ps1 create ScriptBlock objects without running their assertions. The existing green result covers only the invoked portions.

## Deliverable

Invoke the dormant groups and make their failures propagate to the test command. Keep the existing test intent and isolate each fixture as needed.

## Acceptance criteria

- [ ] Every one of the 50 groups listed in the audit's uninvoked-test-blocks.json executes rather than printing its source.
- [ ] A deliberate assertion failure in a representative formerly dormant group makes a disposable copy of the suite exit nonzero.
- [ ] The ordinary suite exits zero after the exercised behavior is verified. Any newly exposed production defect is documented as a blocker instead of weakening or skipping its assertion.
- [ ] Test output distinguishes executed assertions from script text; the existing invoked assertions still run.

## Implementation pointers

- [tests/test_model_routing.ps1](../../../tests/test_model_routing.ps1)

Evidence locations at the reviewed revision: `tests/test_model_routing.ps1:366`. New helper or test filenames under listed directories are implementation choices.

## Verification

Run pwsh -NoProfile -File tests/test_model_routing.ps1, plus the deliberate-failure check in a disposable copy. No live AGY call is needed.

## Scope and constraints

This ticket repairs test execution. Do not change model defaults, retry limits, or production behavior merely to turn the suite green.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

