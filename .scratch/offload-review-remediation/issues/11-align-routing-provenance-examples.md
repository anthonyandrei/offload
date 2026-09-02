---
id: offload-review-11
status: published
priority: P2
labels: [bug, review-remediation, ready-for-agent]
findings: [F-11]
blocked_by: []
---

# 11. Make routing provenance examples match both validators

Blocked by: None

Source: [whole-skill audit](../evidence/review.md), F-11. Reviewed at `cfc9f4e` on 2026-09-03. Published as [#13](https://github.com/anthonyandrei/offload/issues/13). GitHub is the active issue tracker.

## Problem

The instructions attach an individual attempt as worker.routing, but both provenance validators require a schema_version and attempts container.

## Deliverable

Use the existing validator contract, worker.routing = {schema_version: 1, attempts: [...]}. Add a complete reusable fixture and reference it from the shared instructions and web mode.

## Acceptance criteria

- [ ] The exact documented worker object passes both provenance helpers and preserves all recorded attempt fields.
- [ ] A two-attempt example retains both attempts under one stable worker identity.
- [ ] The previously documented bare-attempt shape is rejected by both test paths.
- [ ] The fixture is the source of the complete example or is mechanically checked against it, so documentation and validation cannot drift silently.
- [ ] The root router remains under 500 lines and links to detail instead of duplicating the full record schema.

## Implementation pointers

- [SKILL.md](../../../SKILL.md)
- [modes/web-research.md](../../../modes/web-research.md)
- [tests/test_routing_provenance.ps1](../../../tests/test_routing_provenance.ps1)
- [tests/test_research_modes.sh](../../../tests/test_research_modes.sh)
- [tests/](../../../tests/)

Evidence locations at the reviewed revision: `SKILL.md:143`, `modes/web-research.md:325`, `scripts/collect-provenance.ps1:214`. New helper or test filenames under listed directories are implementation choices.

## Verification

Run the PowerShell routing-provenance suite and a Bash case using the same fixture through collect-provenance.sh. Compare parsed results.

## Scope and constraints

Keep the existing schema version and model policy. This ticket does not make optional embedding mandatory; retention is ticket 14.

Apply the [shared constraints and scheduling notes](../README.md). Do not modify the installed skill copy as part of this ticket.

