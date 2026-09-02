<!-- offload-review-remediation:11 -->

Blocked by: None

Priority: P2. Review findings: F-11. Remediation ticket 11 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

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

## Source evidence

- [SKILL.md:143](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/SKILL.md#L143)
- [modes/web-research.md:325](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md#L325)
- [scripts/collect-provenance.ps1:214](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/collect-provenance.ps1#L214)

## Implementation pointers

- [SKILL.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/SKILL.md)
- [modes/web-research.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md)
- [tests/test_routing_provenance.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_routing_provenance.ps1)
- [tests/test_research_modes.sh](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_research_modes.sh)
- [tests/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/)

New helper or test filenames under listed directories are implementation choices.

## Verification

Run the PowerShell routing-provenance suite and a Bash case using the same fixture through collect-provenance.sh. Compare parsed results.

## Scope and constraints

Keep the existing schema version and model policy. This ticket does not make optional embedding mandatory; retention is #16.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
