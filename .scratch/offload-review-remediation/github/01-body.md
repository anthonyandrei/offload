<!-- offload-review-remediation:01 -->

Blocked by: None

Priority: P2. Review findings: F-09. Remediation ticket 01 of 14.

Reviewed 2026-09-03 against [cfc9f4e](https://github.com/anthonyandrei/offload/commit/cfc9f4edc219b199c5c243c95f91fa2c463d137d).

## Problem

Fifty bare script blocks in tests/test_model_routing.ps1 create ScriptBlock objects without running their assertions. The existing green result covers only the invoked portions.

## Deliverable

Invoke the dormant groups and make their failures propagate to the test command. Keep the existing test intent and isolate each fixture as needed.

## Acceptance criteria

- [ ] Every one of the 50 groups listed in the Source evidence section below executes rather than printing its source.
- [ ] A deliberate assertion failure in a representative formerly dormant group makes a disposable copy of the suite exit nonzero.
- [ ] The ordinary suite exits zero after the exercised behavior is verified. Any newly exposed production defect is documented as a blocker instead of weakening or skipping its assertion.
- [ ] Test output distinguishes executed assertions from script text; the existing invoked assertions still run.

## Source evidence

- [tests/test_model_routing.ps1:366](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_model_routing.ps1#L366)

The audit identified these 50 uninvoked script-block line ranges in the linked test file at the reviewed revision: 366-385, 394-416, 419-438, 441-458, 465-484, 487-508, 511-529, 536-551, 554-569, 572-587, 590-605, 608-622, 625-639, 646-659, 662-676, 679-693, 696-709, 712-727, 730-744, 747-762, 765-779, 782-798, 801-816, 823-838, 841-855, 862-877, 880-895, 898-913, 916-931, 934-949, 952-967, 970-985, 988-1005, 1008-1023, 1026-1041, 1044-1082, 1085-1123, 1126-1166, 1171-1250, 1257-1282, 1285-1299, 1302-1315, 1318-1330, 1333-1347, 1350-1364, 1367-1378, 1381-1391, 1394-1404, 1407-1437, 1440-1455.

## Implementation pointers

- [tests/test_model_routing.ps1](https://github.com/anthonyandrei/offload/blob/cfc9f4edc219b199c5c243c95f91fa2c463d137d/tests/test_model_routing.ps1)

New helper or test filenames under listed directories are implementation choices.

## Verification

Run pwsh -NoProfile -File tests/test_model_routing.ps1, plus the deliberate-failure check in a disposable copy. No live AGY call is needed.

## Scope and constraints

This ticket repairs test execution. Do not change model defaults, retry limits, or production behavior merely to turn the suite green.

- Work in the source repository. Do not update installed skill copies as part of this issue.
- Preserve the Gemini model policy, role routing, maximum two attempts, and immediate quota handoff.
- Preserve Bash 3.2+ compatibility and native PowerShell 7 support. Add no Windows requirement for Bash, Python, or jq.
- Keep the root SKILL.md router below 500 lines; place detailed workflow contracts in the mode documents or supporting files.
- Use fake workers and disposable repositories for regressions. Verify resolved cleanup paths stay inside the test root.
- Shared-file edits still require serialized integration even when issues have no dependency edge.
- Do not use the existing shared-tree offload execution workflow for these fixes until its migration is complete. Use direct orchestration or independently verified isolated checkouts.

The original review exercised PowerShell 7 and Git Bash on Windows. Native Linux, macOS, and Bash 3.2 were not exercised. Record the platforms used for this issue rather than claiming untested parity.
