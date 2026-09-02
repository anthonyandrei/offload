<!-- offload-review-remediation:13 -->

Blocked by: #4, #14

Priority: P2. Review findings: F-12. Remediation ticket 13 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

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

## Source evidence

- [modes/web-research.md:197](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md#L197)
- [modes/web-research.md:210](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md#L210)
- [modes/web-research.md:316](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md#L316)

## Implementation pointers

- [modes/web-research.md](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/modes/web-research.md)
- [tests/test_research_helpers.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_research_helpers.ps1)
- [tests/test_research_modes.sh](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_research_modes.sh)

New helper or test filenames under listed directories are implementation choices.

## Verification

Run fake researcher fixtures through the actual extraction helper in each shell, including a successful PowerShell pipeline capture from #4.

## Scope and constraints

Keep the existing independent-angle threshold and recovery policy. Do not silently drop failing files from provenance.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
