<!-- offload-review-remediation:14 -->

Blocked by: #12, #13, #14

Priority: P2. Review findings: F-10. Remediation ticket 14 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

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

## Source evidence

- [scripts/cleanup-research-workspace.ps1:111](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/cleanup-research-workspace.ps1#L111)
- [scripts/cleanup-research-workspace.sh:130](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/cleanup-research-workspace.sh#L130)
- [SKILL.md:120](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/SKILL.md#L120)

## Implementation pointers

- [scripts/cleanup-research-workspace.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/cleanup-research-workspace.ps1)
- [scripts/cleanup-research-workspace.sh](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/scripts/cleanup-research-workspace.sh)
- [SKILL.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/SKILL.md)
- [modes/repo-research.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/repo-research.md)
- [modes/web-research.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md)
- [tests/test_research_helpers.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_research_helpers.ps1)
- [tests/test_research_modes.sh](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_research_modes.sh)

New helper or test filenames under listed directories are implementation choices.

## Verification

Run paired cleanup fixtures containing successful and failed attempts, absent optional provenance, missing evidence, and an out-of-workspace evidence reference. Verify surviving records and disposal metadata after success and after a repeated cleanup.

## Scope and constraints

Use a separate disposition manifest so the routing schema need not change. It records provenance of cleanup, not a claim that pruned content remains available. Do not retain complete repository snapshots by default.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
