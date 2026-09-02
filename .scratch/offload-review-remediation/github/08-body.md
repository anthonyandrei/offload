<!-- offload-review-remediation:08 -->

Blocked by: None

Priority: P1. Review findings: F-05. Remediation ticket 08 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

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

## Source evidence

- [modes/web-research.md:292](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md#L292)
- [modes/web-research.md:306](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md#L306)

## Implementation pointers

- [modes/web-research.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md)
- [scripts/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/)
- [tests/test_research_modes.sh](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_research_modes.sh)
- [tests/test_workflow_static.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_workflow_static.ps1)
- [tests/](https://github.com/anthonyandrei/offload/tree/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/)

New helper or test filenames under listed directories are implementation choices.

## Verification

Run fixture-based audit acceptance tests for empty, partial, duplicate, unknown, contradictory, and complete results. Use synthetic ledger data and no live browsing.

## Scope and constraints

Do not change what constitutes a trustworthy source in this ticket. This fix checks coverage and internal consistency of the required audit.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
