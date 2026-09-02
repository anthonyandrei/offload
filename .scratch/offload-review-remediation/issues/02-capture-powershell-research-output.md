---
id: offload-review-02
status: published
priority: P1
labels: [bug, review-remediation, ready-for-agent]
findings: [F-01]
blocked_by: []
---

# 02. Make documented PowerShell research handoffs return usable values

Blocked by: None

Source: [whole-skill audit](../evidence/review.md), F-01. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#4](https://github.com/anthonyandrei/offload/issues/4). GitHub is the active issue tracker.

## Problem

The workspace and extraction helpers write to Console.Out, while the mode examples capture the PowerShell pipeline. Workspace.Trim() fails on null, and merged researcher evidence can silently become null.

## Deliverable

Make the helpers emit their result through the PowerShell pipeline and keep diagnostics on the error channel. Test the exact documented in-process assignments and native pwsh -File invocation.

## Acceptance criteria

- [ ] The documented workspace assignment returns one nonempty existing workspace path and .Trim() succeeds.
- [ ] The documented extraction assignment for two valid researcher envelopes returns nonempty JSON containing both findings.
- [ ] Both direct & invocation and native pwsh -File invocation return the same semantic payload without diagnostic text mixed into JSON.
- [ ] Invalid input still fails with the intended exit/error contract, and the mode examples match the tested commands.

## Implementation pointers

- [scripts/make-research-workspace.ps1](../../../scripts/make-research-workspace.ps1)
- [scripts/extract-structured-output.ps1](../../../scripts/extract-structured-output.ps1)
- [modes/repo-research.md](../../../modes/repo-research.md)
- [modes/web-research.md](../../../modes/web-research.md)
- [tests/test_research_helpers.ps1](../../../tests/test_research_helpers.ps1)

Evidence locations at the reviewed revision: `scripts/make-research-workspace.ps1:170`, `scripts/extract-structured-output.ps1:77`, `modes/repo-research.md:40`, `modes/web-research.md:211`. New helper or test filenames under listed directories are implementation choices.

## Verification

Add workflow-shaped cases to tests/test_research_helpers.ps1 using disposable workspaces and fixture envelopes, then run that suite.

## Scope and constraints

Keep the Windows workflow native to PowerShell 7. Do not add Bash, jq, or Python dependencies.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

